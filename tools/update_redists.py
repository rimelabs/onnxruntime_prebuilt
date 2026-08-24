"""Regenerates onnxruntime/onnxruntime_redist_versions.json.

Reads the microsoft/onnxruntime GitHub release listing and records every
prebuilt library archive (the onnxruntime-<os>-<arch>[-<gpu flavor>] tgz/zip
assets) together with the sha256 digest GitHub publishes for the asset.

GitHub only publishes digests for assets uploaded after mid-2025, so the
catalog starts at the oldest release whose archives all carry digests
(v1.23.0 at the time of writing); older releases are skipped rather than
downloaded and hashed locally.

Run via `bazel run //tools:update_redists` (or directly with python3). Set
GITHUB_TOKEN to raise the API rate limit; unauthenticated works too.
"""

import json
import os
import re
import sys
import urllib.request

RELEASES_URL = "https://api.github.com/repos/microsoft/onnxruntime/releases?per_page=100&page={page}"

# onnxruntime-<os>-<arch>[-gpu[_cudaNN]]-<version>.<tgz|zip>
ARCHIVE_ASSET_PATTERN = re.compile(
    r"^onnxruntime-(?P<os>linux|osx|win)-(?P<arch>[a-z0-9_]+?)"
    r"(?:-(?P<flavor>gpu(?:_cuda\d+)?))?"
    r"-(?P<version>\d+\.\d+\.\d+)\.(?:tgz|zip)$"
)

RELEASE_TAG_PATTERN = re.compile(r"^v(\d+\.\d+\.\d+)$")


def fetch_releases():
    headers = {"Accept": "application/vnd.github+json"}
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = "Bearer " + token
    releases = []
    page = 1
    while True:
        request = urllib.request.Request(
            RELEASES_URL.format(page=page), headers=headers
        )
        with urllib.request.urlopen(request) as response:
            batch = json.load(response)
        if not batch:
            return releases
        releases.extend(batch)
        page += 1


def catalog_from_releases(releases):
    catalog = {}
    skipped_undigested = []
    for release in releases:
        tag_match = RELEASE_TAG_PATTERN.match(release["tag_name"])
        if not tag_match or release["prerelease"]:
            continue
        version = tag_match.group(1)
        entries = {}
        undigested = 0
        for asset in release["assets"]:
            asset_match = ARCHIVE_ASSET_PATTERN.match(asset["name"])
            if not asset_match:
                continue
            if asset_match.group("version") != version:
                sys.exit(
                    f"asset {asset['name']} does not match release {version}"
                )
            digest = asset.get("digest") or ""
            if not digest.startswith("sha256:"):
                undigested += 1
                continue
            platform = f"{asset_match.group('os')}-{asset_match.group('arch')}"
            flavor = asset_match.group("flavor") or "cpu"
            entries.setdefault(platform, {})[flavor] = {
                "sha256": digest.removeprefix("sha256:"),
                "url": asset["browser_download_url"],
            }
        if undigested:
            # A partially digested release would be a misleading catalog
            # entry; take only releases GitHub fully covers.
            skipped_undigested.append(version)
        elif entries:
            catalog[version] = {
                platform: dict(sorted(flavors.items()))
                for platform, flavors in sorted(entries.items())
            }
    if skipped_undigested:
        print(
            "skipped releases with undigested archive assets: "
            + ", ".join(sorted(skipped_undigested, key=version_key)),
            file=sys.stderr,
        )
    return dict(sorted(catalog.items(), key=lambda item: version_key(item[0])))


def version_key(version):
    return tuple(int(part) for part in version.split("."))


def main():
    workspace = os.environ.get("BUILD_WORKSPACE_DIRECTORY") or os.path.dirname(
        os.path.dirname(os.path.abspath(__file__))
    )
    output_path = os.path.join(
        workspace, "onnxruntime", "onnxruntime_redist_versions.json"
    )
    catalog = catalog_from_releases(fetch_releases())
    with open(output_path, "w") as output:
        json.dump(catalog, output, indent=2)
        output.write("\n")
    version_count = len(catalog)
    archive_count = sum(
        len(flavors)
        for platforms in catalog.values()
        for flavors in platforms.values()
    )
    print(f"wrote {archive_count} archives across {version_count} versions to {output_path}")


if __name__ == "__main__":
    main()
