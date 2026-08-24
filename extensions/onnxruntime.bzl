"""Module extension exposing prebuilt ONNX Runtime release archives."""

load(
    "//onnxruntime:onnxruntime_redist_build_defs.bzl",
    "get_onnxruntime_redists",
    "onnxruntime_redist_repository",
)

_download = tag_class(
    attrs = {
        "version": attr.string(
            doc = "ONNX Runtime release version, e.g. \"1.24.4\".",
            mandatory = True,
        ),
    },
    doc = """Makes one repository available per distribution archive published
for the release: onnxruntime-<version>-<platform>-<flavor>, where flavor is
"cpu" or a GPU variant ("gpu", "gpu_cuda12", "gpu_cuda13"). Repositories are
fetched lazily, so requesting a version costs nothing for the platforms you
do not build.""",
)

def _onnxruntime_impl(mctx):
    versions = {}
    for module in mctx.modules:
        for download in module.tags.download:
            versions[download.version] = None
    for version in versions:
        for repository_name, redist in get_onnxruntime_redists(mctx, version).items():
            onnxruntime_redist_repository(
                name = repository_name,
                sha256 = redist["sha256"],
                url = redist["url"],
            )
    return mctx.extension_metadata(reproducible = True)

onnxruntime = module_extension(
    doc = "Downloads prebuilt ONNX Runtime distributions from GitHub releases.",
    implementation = _onnxruntime_impl,
    tag_classes = {"download": _download},
)
