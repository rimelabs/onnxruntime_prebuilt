# onnxruntime_prebuilt

A Bazel module that makes the prebuilt [ONNX Runtime](https://github.com/microsoft/onnxruntime)
library distributions from GitHub releases available as hermetic, checksum-pinned
external repositories — both the CPU-only `onnxruntime` archives and the
`onnxruntime-gpu` (CUDA) archives, for every platform Microsoft publishes.

## Usage

```starlark
bazel_dep(name = "onnxruntime_prebuilt", version = "0.1.0")

onnxruntime = use_extension("@onnxruntime_prebuilt//extensions:onnxruntime.bzl", "onnxruntime")
use_repo(onnxruntime, "onnxruntime", "onnxruntime-gpu")
```

`@onnxruntime` (CPU) and `@onnxruntime-gpu` (newest CUDA variant) carry the
default ONNX Runtime version pinned in this module's MODULE.bazel and
dispatch to the archive matching the target platform. To re-pin the default
or use additional versions side by side, add `download` tags:

```starlark
onnxruntime.download(version = "1.29.0", default = True)  # re-pin @onnxruntime[-gpu]
onnxruntime.download(version = "1.24.4")                  # versioned repos only
use_repo(onnxruntime, "onnxruntime-gpu", "onnxruntime-1.24.4-linux-x64-gpu_cuda13")
```

(The first `default = True` tag in breadth-first module order wins, so a root
module's re-pin beats this module's pin.)

Each requested version provides two layers of repositories:

- **`onnxruntime-<version>-<flavor>`** — one per flavor, dispatching on the
  target platform: its targets are aliases that `select()` on
  `@platforms//os` + `@platforms//cpu` constraints and resolve to the
  matching archive. Use these unless you need an explicit platform.
- **`onnxruntime-<version>-<platform>-<flavor>`** — one per published archive,
  for explicit platform choices. `<platform>` is spelled as in the release
  asset names (`linux-x64`, `linux-aarch64`, `osx-arm64`, `win-x64`, ...).
  The `osx-universal2` and `win-arm64x` archives overlap the per-architecture
  constraint sets, so they are only reachable this way.

`<flavor>` is `cpu` for the plain archives, or the GPU variant suffix from the
asset name (`gpu`, `gpu_cuda12`, `gpu_cuda13`).

Repositories are fetched lazily — only the archives whose targets you build
are downloaded; a selector only depends on the archive its `select()` chooses.
Every download is pinned to the sha256 digest GitHub publishes for the release
asset.

### Targets

All repository layers (unversioned, per-flavor, per-archive) expose:

| Target | Contents |
| --- | --- |
| `:lib` | The shared libraries as shipped, including the SONAME symlink chain (`libonnxruntime.so` → `.so.1` → `.so.<version>`) |
| `:shared_library` | The main shared library by its linker name, e.g. for `$(rootpath ...)` into an `ORT_DYLIB_PATH`-style setting |
| `:include` | The C/C++ headers |
| `:pkg` | `rules_pkg` tarball of `:lib` rooted at `/usr/lib`, for layering into container images |

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
bazel build @onnxruntime//... @onnxruntime-gpu//...
```

The second command resolves the selectors for the host platform, downloads
the chosen CPU and GPU archives, and builds every exposed target from them.
