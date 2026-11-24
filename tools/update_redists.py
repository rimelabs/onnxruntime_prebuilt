"""Regenerates onnxruntime/onnxruntime_redist_versions.json.

Records, for every stable ONNX Runtime release from 1.22.0, the native
libraries Microsoft publishes as NuGet packages:

- cpu: Microsoft.ML.OnnxRuntime on nuget.org, one package for every platform.
- gpu (CUDA 12; named gpu_cuda12 from 1.27): Microsoft.ML.OnnxRuntime.Gpu.Linux
  and .Gpu.Windows on nuget.org.
- gpu_cuda13: the same two packages on Microsoft's onnxruntime-cuda-13 feed.

Each catalog entry names one platform of one package: the package url, its
integrity, and the package directories holding that platform's libraries and
the headers. nuget.org publishes each package's sha512 and file list; the
onnxruntime-cuda-13 feed publishes neither, so its packages are downloaded
and hashed. Entries already in the catalog are kept without fetching again,
since a published package version never changes.

Run via `bazel run //tools:update_redists` (or directly with python3).
"""

import base64
import hashlib
import json
import os
import re
import sys
import tempfile
import urllib.error
import urllib.request
import zipfile

NUGET_ORG = "https://api.nuget.org/v3"
CUDA_13_FEED = (
    "https://aiinfra.pkgs.visualstudio.com/PublicPackages/_packaging/"
    "onnxruntime-cuda-13/nuget/v3/index.json"
)

OLDEST_VERSION = (1, 22, 0)

# NuGet runtime identifiers and the platform names the catalog uses for them.
PLATFORMS = {
    "linux-arm64": "linux-aarch64",
    "linux-x64": "linux-x64",
    "osx-arm64": "osx-arm64",
    "osx-x64": "osx-x86_64",
    "win-arm64": "win-arm64",
    "win-x64": "win-x64",
    "win-x86": "win-x86",
}

RUNTIME_DIRECTORY = re.compile(r"^(runtimes/([^/]+)/native)/[^/]+$")
HEADER = "onnxruntime_c_api.h"
STABLE_VERSION = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")


def get_json(url):
    request = urllib.request.Request(url, headers={"Accept-Encoding": "identity"})
    with urllib.request.urlopen(request) as response:
        return json.load(response)


def package_base_address(index_url):
    for resource in get_json(index_url)["resources"]:
        if resource["@type"].startswith("PackageBaseAddress"):
            return resource["@id"]
    sys.exit(f"{index_url} names no PackageBaseAddress")


class Feed:
    def __init__(self, index_url):
        self.base = package_base_address(index_url)

    def versions(self, package):
        try:
            listing = get_json(f"{self.base}{package.lower()}/index.json")
        except urllib.error.HTTPError as error:
            if error.code == 404:
                return set()
            raise
        return {
            version
            for version in listing["versions"]
            if STABLE_VERSION.match(version)
            and version_key(version) >= OLDEST_VERSION
        }

    def url(self, package, version):
        lower = package.lower()
        return f"{self.base}{lower}/{version}/{lower}.{version}.nupkg"

    def describe(self, package, version):
        """Returns the package's integrity and file names."""
        url = self.url(package, version)
        print(f"downloading {url}", file=sys.stderr)
        digest = hashlib.sha512()
        with tempfile.TemporaryFile() as package_file:
            with urllib.request.urlopen(url) as response:
                while chunk := response.read(1 << 20):
                    digest.update(chunk)
                    package_file.write(chunk)
            names = zipfile.ZipFile(package_file).namelist()
        return integrity(digest.digest()), names


class NugetOrg(Feed):
    def __init__(self):
        super().__init__(f"{NUGET_ORG}/index.json")

    def describe(self, package, version):
        registration = get_json(
            f"{NUGET_ORG}/registration5-semver1/{package.lower()}/{version}.json"
        )
        entry = get_json(registration["catalogEntry"])
        if entry["packageHashAlgorithm"] != "SHA512":
            sys.exit(f"{package} {version} is hashed with {entry['packageHashAlgorithm']}")
        names = [package_entry["fullName"] for package_entry in entry["packageEntries"]]
        return integrity(base64.b64decode(entry["packageHash"])), names


def integrity(sha512):
    return "sha512-" + base64.b64encode(sha512).decode()


def platform_entries(url, package_integrity, names):
    """Returns one catalog entry per platform the package carries."""
    headers = sorted(name for name in names if name.endswith("/include/" + HEADER))
    if not headers:
        sys.exit(f"{url} carries no {HEADER}")
    include_directory = headers[0].removesuffix("/" + HEADER)
    entries = {}
    for name in names:
        match = RUNTIME_DIRECTORY.match(name)
        if match and match.group(2) in PLATFORMS:
            entries[PLATFORMS[match.group(2)]] = {
                "include_directory": include_directory,
                "integrity": package_integrity,
                "library_directory": match.group(1),
                "url": url,
            }
    return entries


def cuda_12_flavor(version):
    return "gpu_cuda12" if version_key(version) >= (1, 27, 0) else "gpu"


def version_key(version):
    return tuple(int(part) for part in version.split("."))


def main():
    workspace = os.environ.get("BUILD_WORKSPACE_DIRECTORY") or os.path.dirname(
        os.path.dirname(os.path.abspath(__file__))
    )
    output_path = os.path.join(
        workspace, "onnxruntime", "onnxruntime_redist_versions.json"
    )
    # The recorded entries of each package, by platform.
    recorded = {}
    with open(output_path) as recorded_file:
        for platforms in json.load(recorded_file).values():
            for platform, flavors in platforms.items():
                for entry in flavors.values():
                    if "integrity" in entry:
                        recorded.setdefault(entry["url"], {})[platform] = entry

    nuget_org = NugetOrg()
    cuda_13_feed = Feed(CUDA_13_FEED)
    sources = [
        (nuget_org, "Microsoft.ML.OnnxRuntime", lambda version: "cpu"),
        (nuget_org, "Microsoft.ML.OnnxRuntime.Gpu.Linux", cuda_12_flavor),
        (nuget_org, "Microsoft.ML.OnnxRuntime.Gpu.Windows", cuda_12_flavor),
        (cuda_13_feed, "Microsoft.ML.OnnxRuntime.Gpu.Linux", lambda version: "gpu_cuda13"),
        (cuda_13_feed, "Microsoft.ML.OnnxRuntime.Gpu.Windows", lambda version: "gpu_cuda13"),
    ]
    catalog = {}
    for feed, package, flavor_of in sources:
        for version in sorted(feed.versions(package), key=version_key):
            url = feed.url(package, version)
            entries = recorded.get(url) or platform_entries(
                url, *feed.describe(package, version)
            )
            for platform, entry in entries.items():
                catalog.setdefault(version, {}).setdefault(platform, {})[
                    flavor_of(version)
                ] = entry

    catalog = {
        version: {
            platform: dict(sorted(flavors.items()))
            for platform, flavors in sorted(platforms.items())
        }
        for version, platforms in sorted(catalog.items(), key=lambda item: version_key(item[0]))
    }
    with open(output_path, "w") as output:
        json.dump(catalog, output, indent=2)
        output.write("\n")
    archive_count = sum(
        len(flavors) for platforms in catalog.values() for flavors in platforms.values()
    )
    print(f"wrote {archive_count} distributions across {len(catalog)} versions to {output_path}")


if __name__ == "__main__":
    main()
