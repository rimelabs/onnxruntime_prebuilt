"""Registry and repository rule for prebuilt ONNX Runtime distributions."""

_ONNXRUNTIME_REDIST_VERSIONS_JSON = Label("//onnxruntime:onnxruntime_redist_versions.json")

_BUILD_TEMPLATE = Label("//onnxruntime/build_defs:onnxruntime.BUILD.bazel")

# Platforms a selector repository can pick with a config_setting on target
# constraints.
_SELECTOR_PLATFORM_CONSTRAINTS = {
    "linux-aarch64": ["@platforms//os:linux", "@platforms//cpu:aarch64"],
    "linux-x64": ["@platforms//os:linux", "@platforms//cpu:x86_64"],
    "osx-arm64": ["@platforms//os:macos", "@platforms//cpu:aarch64"],
    "osx-x86_64": ["@platforms//os:macos", "@platforms//cpu:x86_64"],
    "win-arm64": ["@platforms//os:windows", "@platforms//cpu:aarch64"],
    "win-x64": ["@platforms//os:windows", "@platforms//cpu:x86_64"],
    "win-x86": ["@platforms//os:windows", "@platforms//cpu:x86_32"],
}

def platform_repository_name(version, platform, flavor):
    return "onnxruntime-{}-{}-{}".format(version, platform, flavor)

def selector_repository_name(version, flavor):
    return "onnxruntime-{}-{}".format(version, flavor)

def default_gpu_flavor(flavors):
    """Returns the GPU flavor @onnxruntime-gpu should carry: the newest CUDA.

    The plain "gpu" flavor (CUDA 12, renamed gpu_cuda12 in 1.27) ranks below
    the explicitly suffixed ones. Returns None if the version has no GPU
    distributions at all.
    """
    best = None
    best_rank = -1
    for flavor in flavors:
        if not flavor.startswith("gpu"):
            continue
        rank = int(flavor.removeprefix("gpu_cuda")) if flavor.startswith("gpu_cuda") else 0
        if rank > best_rank:
            best = flavor
            best_rank = rank
    return best

def get_onnxruntime_redists(mctx, version):
    """Returns the distributions the catalog holds for a version.

    Args:
        mctx: the module extension context, used to read the catalog.
        version: the ONNX Runtime release version, e.g. "1.24.4".

    Returns:
        A dict mapping platforms (e.g. "linux-x64") to dicts mapping flavors
        ("cpu", "gpu", "gpu_cuda12", "gpu_cuda13") to the keyword arguments
        of onnxruntime_redist_repository other than version.
    """
    catalog = json.decode(mctx.read(_ONNXRUNTIME_REDIST_VERSIONS_JSON))
    if version not in catalog:
        fail(
            "ONNX Runtime version {} is not in the redistribution catalog ".format(version) +
            "(known versions: {}). If the release exists, refresh the catalog ".format(", ".join(catalog.keys())) +
            "with `bazel run //tools:update_redists` in onnxruntime_prebuilt.",
        )
    return catalog[version]

def _reproducible(rctx, reproducible):
    """Lets Bazel 8.3 and later share the repository's contents across
    workspaces when it is reproducible; earlier versions have no
    repo_metadata."""
    if hasattr(rctx, "repo_metadata"):
        return rctx.repo_metadata(reproducible = reproducible)
    return None

# For each platform's main library: the versioned file name its install name
# gives, and the links the linker and the dynamic loader find it by.
_LIBRARY_NAMES = {
    "libonnxruntime.dylib": lambda version: (
        "libonnxruntime.{}.dylib".format(version),
        ["libonnxruntime.dylib"],
    ),
    "libonnxruntime.so": lambda version: (
        "libonnxruntime.so.{}".format(version),
        ["libonnxruntime.so.1", "libonnxruntime.so"],
    ),
}

def _relative_symlink(rctx, target, link):
    """Links link to target, a name in the same directory; rctx.symlink
    makes absolute links, which break once Bazel moves the repository."""
    result = rctx.execute(["ln", "-s", target, link])
    if result.return_code != 0:
        fail("cannot link {} to {}: {}".format(link, target, result.stderr))

def _onnxruntime_redist_repository_impl(rctx):
    rctx.download_and_extract(
        output = "_package",
        integrity = rctx.attr.integrity,
        type = "zip",
        url = rctx.attr.url,
    )
    rctx.rename("_package/" + rctx.attr.include_directory, "include")
    rctx.rename("_package/" + rctx.attr.library_directory, "lib")
    for notice in ["LICENSE", "ThirdPartyNotices.txt"]:
        if rctx.path("_package/" + notice).exists:
            rctx.rename("_package/" + notice, notice)
    rctx.delete("_package")

    for name, names in _LIBRARY_NAMES.items():
        if rctx.path("lib/" + name).exists:
            versioned, links = names(rctx.attr.version)
            rctx.rename("lib/" + name, "lib/" + versioned)
            target = versioned
            for link in links:
                _relative_symlink(rctx, target, "lib/" + link)
                target = link

    rctx.template("BUILD.bazel", rctx.attr.build_template)
    return _reproducible(rctx, True)

onnxruntime_redist_repository = repository_rule(
    doc = """Downloads one platform's libraries and headers from a prebuilt
ONNX Runtime NuGet package, laid out as lib/ and include/.""",
    implementation = _onnxruntime_redist_repository_impl,
    attrs = {
        "build_template": attr.label(
            allow_single_file = True,
            default = _BUILD_TEMPLATE,
        ),
        "include_directory": attr.string(
            doc = "The package directory holding the headers, e.g. \"build/native/include\".",
            mandatory = True,
        ),
        "integrity": attr.string(
            doc = "The package's Subresource Integrity, e.g. \"sha512-...\".",
            mandatory = True,
        ),
        "library_directory": attr.string(
            doc = "The package directory holding the platform's libraries, e.g. \"runtimes/linux-x64/native\".",
            mandatory = True,
        ),
        "url": attr.string(mandatory = True),
        "version": attr.string(
            doc = "The ONNX Runtime version, e.g. \"1.24.4\", which names the versioned library.",
            mandatory = True,
        ),
    },
)

_SELECTED_TARGETS = [
    "include",
    "lib",
    "pkg",
    "shared_library",
]

def selectable_platforms(platforms):
    """Filters a version's platforms down to those a selector can dispatch on."""
    return [p for p in platforms if p in _SELECTOR_PLATFORM_CONSTRAINTS]

def _onnxruntime_selector_repository_impl(rctx):
    platforms = sorted(rctx.attr.platform_repos)
    lines = [
        "# Dispatches to the platform repository matching the target platform.",
        "",
        'package(default_visibility = ["//visibility:public"])',
    ]
    for platform in platforms:
        lines += [
            "",
            "config_setting(",
            '    name = "{}",'.format(platform),
            "    constraint_values = [",
        ] + [
            '        "{}",'.format(constraint)
            for constraint in _SELECTOR_PLATFORM_CONSTRAINTS[platform]
        ] + [
            "    ],",
            ")",
        ]
    no_match_error = "this ONNX Runtime distribution is only published for: {}".format(
        ", ".join(platforms),
    )
    for target in _SELECTED_TARGETS:
        lines += [
            "",
            "alias(",
            '    name = "{}",'.format(target),
            "    actual = select(",
            "        {",
        ] + [
            '            ":{}": "@{}//:{}",'.format(
                platform,
                rctx.attr.platform_repos[platform],
                target,
            )
            for platform in platforms
        ] + [
            "        },",
            '        no_match_error = "{}",'.format(no_match_error),
            "    ),",
            ")",
        ]
    rctx.file("BUILD.bazel", "\n".join(lines) + "\n")
    return _reproducible(rctx, True)

onnxruntime_selector_repository = repository_rule(
    doc = """Exposes one ONNX Runtime distribution flavor of one version,
dispatching to the per-platform repository matching the target
platform via constraint-based config_settings.""",
    implementation = _onnxruntime_selector_repository_impl,
    attrs = {
        "platform_repos": attr.string_dict(
            doc = "Maps platform (e.g. \"linux-x64\") to the platform repository name.",
            mandatory = True,
        ),
    },
)
