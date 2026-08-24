"""Module extension exposing prebuilt ONNX Runtime release archives."""

load(
    "//onnxruntime:onnxruntime_redist_build_defs.bzl",
    "default_gpu_flavor",
    "get_onnxruntime_redists",
    "onnxruntime_redist_repository",
    "onnxruntime_selector_repository",
    "platform_repository_name",
    "selectable_platforms",
    "selector_repository_name",
)

_download = tag_class(
    attrs = {
        "default": attr.bool(
            default = False,
            doc = """Expose this version through the unversioned @onnxruntime
(CPU) and @onnxruntime-gpu (newest CUDA variant) repositories. The first
default tag in breadth-first module order wins, so the root module's pin
beats any dependency's.""",
        ),
        "version": attr.string(
            doc = "ONNX Runtime release version, e.g. \"1.24.4\".",
            mandatory = True,
        ),
    },
    doc = """Makes the release's distribution archives available: one
repository per flavor — onnxruntime-<version>-<flavor>, where flavor is
"cpu" or a GPU variant ("gpu", "gpu_cuda12", "gpu_cuda13") — dispatching on
the target platform, plus one repository per archive
(onnxruntime-<version>-<platform>-<flavor>) for explicit platform choices.
Repositories are fetched lazily, so requesting a version costs nothing for
the platforms and flavors you do not build.""",
)

def _onnxruntime_impl(mctx):
    versions = {}
    default_version = None
    for module in mctx.modules:
        for download in module.tags.download:
            versions[download.version] = None
            if download.default and default_version == None:
                default_version = download.version
    for version in versions:
        flavor_platforms = {}
        for platform, flavors in get_onnxruntime_redists(mctx, version).items():
            for flavor, redist in flavors.items():
                onnxruntime_redist_repository(
                    name = platform_repository_name(version, platform, flavor),
                    sha256 = redist["sha256"],
                    url = redist["url"],
                )
                flavor_platforms.setdefault(flavor, []).append(platform)
        for flavor, platforms in flavor_platforms.items():
            platform_repos = {
                platform: platform_repository_name(version, platform, flavor)
                for platform in selectable_platforms(platforms)
            }
            if platform_repos:
                onnxruntime_selector_repository(
                    name = selector_repository_name(version, flavor),
                    platform_repos = platform_repos,
                )

        # The unversioned repositories carrying the pinned default version.
        if version == default_version:
            unversioned = {
                "onnxruntime": "cpu",
                "onnxruntime-gpu": default_gpu_flavor(flavor_platforms.keys()),
            }
            for repository_name, flavor in unversioned.items():
                if flavor == None:
                    continue
                onnxruntime_selector_repository(
                    name = repository_name,
                    platform_repos = {
                        platform: platform_repository_name(version, platform, flavor)
                        for platform in selectable_platforms(flavor_platforms[flavor])
                    },
                )
    return mctx.extension_metadata(reproducible = True)

onnxruntime = module_extension(
    doc = "Downloads prebuilt ONNX Runtime distributions from GitHub releases.",
    implementation = _onnxruntime_impl,
    tag_classes = {"download": _download},
)
