# onnxruntime_prebuilt

A Bazel module that makes the prebuilt [ONNX Runtime](https://onnxruntime.ai)
libraries Microsoft publishes as NuGet packages available as hermetic,
integrity-pinned external repositories — both the CPU-only `onnxruntime`
libraries and the `onnxruntime-gpu` (CUDA) libraries, for every platform the
packages carry.

## Usage

```starlark
bazel_dep(name = "onnxruntime_prebuilt", version = "0.2.0")

onnxruntime = use_extension("@onnxruntime_prebuilt//extensions:onnxruntime.bzl", "onnxruntime")
onnxruntime.download(
    default = True,
    version = "1.24.4",
)
use_repo(onnxruntime, "onnxruntime", "onnxruntime-gpu")
```

The consumer pins the ONNX Runtime version; `default = True` additionally
exposes that version as the unversioned `@onnxruntime` (CPU) and
`@onnxruntime-gpu` (newest CUDA variant) repositories, which dispatch to the
distribution matching the target platform. Multiple versions can be requested
side by side with further `download` tags. (The first `default = True` tag
in breadth-first module order wins, so a root module's pin beats any
dependency's.)

Each requested version provides two layers of repositories:

- **`onnxruntime-<version>-<flavor>`** — one per flavor, dispatching on the
  target platform: its targets are aliases that `select()` on
  `@platforms//os` + `@platforms//cpu` constraints and resolve to the
  matching platform. Use these unless you need an explicit platform.
- **`onnxruntime-<version>-<platform>-<flavor>`** — one per platform, for
  explicit platform choices: `linux-x64`, `linux-aarch64`, `osx-arm64`,
  `win-x64`, `win-arm64`, ...

`<flavor>` is `cpu`, or the CUDA variant: `gpu` (CUDA 12, before 1.27),
`gpu_cuda12` (from 1.27) or `gpu_cuda13`.

Repositories are fetched lazily — only the packages whose targets you build
are downloaded; a selector only depends on the platform its `select()`
chooses. Every download is pinned to the package's sha512. One package holds
several platforms, and the repository cache downloads it once for all of them.

### Targets

All repository layers (unversioned, per-flavor, per-platform) expose:

| Target | Contents |
| --- | --- |
| `:lib` | The shared libraries, including the SONAME symlink chain (`libonnxruntime.so` → `.so.1` → `.so.<version>`; `libonnxruntime.dylib` → `libonnxruntime.<version>.dylib`) |
| `:shared_library` | The main shared library by its linker name, e.g. for `$(rootpath ...)` into an `ORT_DYLIB_PATH`-style setting |
| `:include` | The C/C++ headers |
| `:pkg` | `rules_pkg` tarball of `:lib` rooted at `/usr/lib`, for layering into container images |

## Version catalog

`onnxruntime/onnxruntime_redist_versions.json` records every stable release
from 1.22.0 of these NuGet packages, each platform with the package url, its
sha512 and the package directories holding the platform's libraries and the
headers:

| Flavor | Package | Feed |
| --- | --- | --- |
| `cpu` | `Microsoft.ML.OnnxRuntime` | nuget.org |
| `gpu`, `gpu_cuda12` | `Microsoft.ML.OnnxRuntime.Gpu.Linux`, `.Gpu.Windows` | nuget.org |
| `gpu_cuda13` | `Microsoft.ML.OnnxRuntime.Gpu.Linux`, `.Gpu.Windows` | Microsoft's [`onnxruntime-cuda-13`](https://aiinfra.visualstudio.com/PublicPackages/_artifacts/feed/onnxruntime-cuda-13) feed |

Refresh the catalog after a new ONNX Runtime release:

```shell
bazel run //tools:update_redists
```

nuget.org publishes each package's sha512 and file list. The
`onnxruntime-cuda-13` feed publishes neither, so the tool downloads and
hashes its new packages; recorded entries are kept as they are.

## Verification

```shell
bazel build //...
bazel build @onnxruntime//... @onnxruntime-gpu//...
```

The second command resolves the selectors for the host platform, downloads
the chosen CPU and GPU packages, and builds every exposed target from them.
The consumer-facing surface is exercised from the `e2e/` test module (the
same one the Bazel Central Registry presubmit runs):

```shell
cd e2e && bazel build //:cpu_distribution //:gpu_distribution
```

## Releasing

1. Bump `version` in MODULE.bazel (a PR; `main` requires one).
2. Tag the release commit: `git tag vX.Y.Z && git push origin vX.Y.Z`.

The Release workflow then creates the GitHub release with a stable source
archive (`onnxruntime_prebuilt-vX.Y.Z.tar.gz`) and a usage snippet, and the
Publish to BCR workflow opens a Bazel Central Registry pull request from the
templates in `.bcr/`. The publish workflow needs a `BCR_PUBLISH_TOKEN`
repository secret (a classic PAT that can push to the registry fork named in
`.github/workflows/publish.yaml`); without it, dispatch the BCR pull request
manually.
