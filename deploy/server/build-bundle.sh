#!/usr/bin/env bash
# Build the release bundle a server installs from (no checkout needed there):
#
#   deploy/server/build-bundle.sh <version> <image owner> [out dir]
#   e.g. deploy/server/build-bundle.sh 0.2.0 dnk8n dist
#
# Writes <out>/dtrack-server-<version>.tar.gz and its .sha256. The bundle
# holds compose.yaml with every DTrack image pinned to <version>, the .env
# template, the cron file, install.sh and VERSION. Run by
# .github/workflows/bundle.yml, which attaches both files to the release.
set -euo pipefail

version="${1:?usage: $0 <version> <image owner> [out dir]}"
owner="${2:?usage: $0 <version> <image owner> [out dir]}"
# The out dir is relative to where you run this, not to this script.
out="$(mkdir -p "${3:-dist}" && cd "${3:-dist}" && pwd)"
cd "$(dirname "$0")"
[[ "$version" =~ ^[0-9A-Za-z][0-9A-Za-z._-]*$ ]] || { echo "bad version: $version" >&2; exit 2; }
[[ "$owner" =~ ^[0-9A-Za-z-]+$ ]] || { echo "bad owner: $owner" >&2; exit 2; }

name="dtrack-server-$version"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/$name"

sed -e "s|\${IMAGE_OWNER:-dnk8n}|$owner|g" \
    -e "s|\${IMAGE_TAG:?set IMAGE_TAG in .env}|$version|g" \
    compose.yaml >"$work/$name/compose.yaml"
if grep -q 'IMAGE_' "$work/$name/compose.yaml"; then
    echo "compose.yaml still references IMAGE_* after pinning" >&2
    exit 1
fi
cp env.tpl cron "$work/$name/"
install -m 755 install.sh "$work/$name/install.sh"
echo "$version" >"$work/$name/VERSION"

tar -C "$work" --owner=0 --group=0 --sort=name -czf "$out/$name.tar.gz" "$name"
(cd "$out" && sha256sum "$name.tar.gz" >"$name.tar.gz.sha256")
echo "$out/$name.tar.gz"
