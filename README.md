# onnxruntime_prebuilt

A Bazel module that makes the prebuilt [ONNX Runtime](https://github.com/microsoft/onnxruntime)
library distributions from GitHub releases available as hermetic, checksum-pinned
external repositories — both the CPU-only `onnxruntime` archives and the
`onnxruntime-gpu` (CUDA) archives, for every platform Microsoft publishes.

## Usage

```starlark
bazel_dep(name = "onnxruntime_prebuilt", version = "0.1.0")

onnxruntime = use_extension("@onnxruntime_prebuilt//extensions:onnxruntime.bzl", "onnxruntime")
onnxruntime.download(version = "1.24.4")
use_repo(
    onnxruntime,
    onnxruntime = "onnxruntime-1.24.4-linux-x64-cpu",
    onnxruntime_gpu = "onnxruntime-1.24.4-linux-x64-gpu_cuda13",
)
```

Each `download` tag makes one repository available per distribution archive
published for that release, named `onnxruntime-<version>-<platform>-<flavor>`:

- `<platform>`: `linux-x64`, `linux-aarch64`, `osx-arm64`, `win-x64`, ... —
  as in the release asset names.
- `<flavor>`: `cpu` for the plain archives, or the GPU variant suffix from the
  asset name (`gpu`, `gpu_cuda12`, `gpu_cuda13`).

Repositories are fetched lazily: only the archives whose targets you build are
downloaded. Every download is pinned to the sha256 digest GitHub publishes for
the release asset.

### Targets

Each repository exposes:

| Target | Contents |
| --- | --- |
| `:lib` | The shared libraries as shipped, including the SONAME symlink chain (`libonnxruntime.so` → `.so.1` → `.so.<version>`) |
| `:include` | The C/C++ headers |
| `:pkg` | `rules_pkg` tarball of `:lib` rooted at `/usr/lib`, for layering into container images |

Individual files can be addressed directly, e.g.
`@onnxruntime_gpu//:lib/libonnxruntime.so`.

## Version catalog

`onnxruntime/onnxruntime_redist_versions.json` records every prebuilt library
archive (`onnxruntime-<os>-<arch>[-<gpu flavor>]-<version>.{tgz,zip}`) of every
`microsoft/onnxruntime` release, with the sha256 digest GitHub publishes for
the asset. GitHub only publishes digests for assets uploaded after mid-2025,
so the catalog starts at v1.22.1 (the oldest release whose archives all carry
digests); NuGet packages and other non-archive assets are not covered.

Refresh the catalog after a new ONNX Runtime release:

```shell
bazel run //tools:update_redists
```

(`GITHUB_TOKEN` raises the API rate limit but is not required.)

## Verification

```shell
bazel build //...
bazel build @onnxruntime-1.24.4-linux-x64-cpu//... @onnxruntime-1.24.4-linux-x64-gpu_cuda13//...
```

The second command downloads the linux-x64 CPU and GPU archives and builds
every exposed target from them.
