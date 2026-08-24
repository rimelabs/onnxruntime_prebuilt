"""Registry and repository rule for prebuilt ONNX Runtime distributions."""

_ONNXRUNTIME_REDIST_VERSIONS_JSON = Label("//onnxruntime:onnxruntime_redist_versions.json")

_BUILD_TEMPLATE = Label("//onnxruntime/build_defs:onnxruntime.BUILD.bazel")

# Platforms whose archives a selector repository can pick with a
# config_setting on target constraints. osx-universal2 and win-arm64x
# overlap the per-architecture archives (no distinct constraint set), so
# they are reachable only as explicit per-platform repositories.
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
    archives at all.
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
    """Returns the distribution archives the catalog holds for a version.

    Args:
        mctx: the module extension context, used to read the catalog.
        version: the ONNX Runtime release version, e.g. "1.24.4".

    Returns:
        A dict mapping platforms (e.g. "linux-x64") to dicts mapping flavors
        ("cpu", "gpu", "gpu_cuda12", "gpu_cuda13") to {"url": ..., "sha256": ...}
        download descriptors.
    """
    catalog = json.decode(mctx.read(_ONNXRUNTIME_REDIST_VERSIONS_JSON))
    if version not in catalog:
        fail(
            "ONNX Runtime version {} is not in the redistribution catalog ".format(version) +
            "(known versions: {}). If the release exists, refresh the catalog ".format(", ".join(catalog.keys())) +
            "with `bazel run //tools:update_redists` in onnxruntime_prebuilt.",
        )
    return catalog[version]

def _onnxruntime_redist_repository_impl(rctx):
    rctx.download_and_extract(
        output = "_archive",
        sha256 = rctx.attr.sha256,
        url = rctx.attr.url,
    )

    # Release archives wrap their contents in a single top-level directory
    # whose name is not always derivable from the archive name (the
    # *-gpu_cuda13 archives extract to a plain *-gpu-* directory), so link
    # the contents of whatever directory is there instead of stripping a
    # recorded prefix.
    entries = rctx.path("_archive").readdir()
    if len(entries) != 1 or not entries[0].is_dir:
        fail("expected a single top-level directory in {}, found {}".format(
            rctx.attr.url,
            entries,
        ))
    for child in entries[0].readdir():
        rctx.symlink(child, child.basename)

    rctx.template("BUILD.bazel", rctx.attr.build_template)

onnxruntime_redist_repository = repository_rule(
    doc = "Downloads and exposes one prebuilt ONNX Runtime distribution archive.",
    implementation = _onnxruntime_redist_repository_impl,
    attrs = {
        "build_template": attr.label(
            allow_single_file = True,
            default = _BUILD_TEMPLATE,
        ),
        "sha256": attr.string(mandatory = True),
        "url": attr.string(mandatory = True),
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
        "# Dispatches to the archive repository matching the target platform.",
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

onnxruntime_selector_repository = repository_rule(
    doc = """Exposes one ONNX Runtime distribution flavor of one version,
dispatching to the per-platform archive repository matching the target
platform via constraint-based config_settings.""",
    implementation = _onnxruntime_selector_repository_impl,
    attrs = {
        "platform_repos": attr.string_dict(
            doc = "Maps platform (e.g. \"linux-x64\") to the archive repository name.",
            mandatory = True,
        ),
    },
)
