"""Registry and repository rule for prebuilt ONNX Runtime distributions."""

_ONNXRUNTIME_REDIST_VERSIONS_JSON = Label("//onnxruntime:onnxruntime_redist_versions.json")

_BUILD_TEMPLATE = Label("//onnxruntime/build_defs:onnxruntime.BUILD.bazel")

def get_onnxruntime_redists(mctx, version):
    """Returns the distribution archives the catalog holds for a version.

    Args:
        mctx: the module extension context, used to read the catalog.
        version: the ONNX Runtime release version, e.g. "1.24.4".

    Returns:
        A dict mapping repository names (onnxruntime-<version>-<platform>-<flavor>)
        to {"url": ..., "sha256": ...} download descriptors.
    """
    catalog = json.decode(mctx.read(_ONNXRUNTIME_REDIST_VERSIONS_JSON))
    if version not in catalog:
        fail(
            "ONNX Runtime version {} is not in the redistribution catalog ".format(version) +
            "(known versions: {}). If the release exists, refresh the catalog ".format(", ".join(catalog.keys())) +
            "with `bazel run //tools:update_redists` in onnxruntime_prebuilt.",
        )
    redists = {}
    for platform, flavors in catalog[version].items():
        for flavor, redist in flavors.items():
            redists["onnxruntime-{}-{}-{}".format(version, platform, flavor)] = redist
    return redists

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
