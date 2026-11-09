#!/usr/bin/env bash
# Downloads the PowerSync SQLite core extension for Linux and checks its SHA-256.
#
# There's no Linux build of the core xcframework, so on Linux `registerPowerSyncCoreExtension()`
# loads this shared library at runtime: from $POWERSYNC_CORE_PATH, else
# /usr/local/lib/libpowersync_<arch>.so. The version is the core that powersync-sqlite-core-swift
# 0.4.13 (pinned in Package.swift) wraps; update both together.
#
# Usage: scripts/fetch-linux-core.sh [DEST_DIR]   (default /usr/local/lib)
# Prints the path of the library it installed.
set -euo pipefail

version=v0.4.13
case "$(uname -m)" in
  x86_64)
    arch=x64
    sha256=b9885eb188ee827453bd94100b657cda76e23722610abf2e33170ca15d2c0de3
    ;;
  aarch64 | arm64)
    arch=aarch64
    sha256=53a4250821a317705a864e3b4dc2e4cdaacc24ebc1cfe37bdf99148b024c9144
    ;;
  *)
    echo "fetch-linux-core.sh: no PowerSync core build for $(uname -m)" >&2
    exit 1
    ;;
esac

dest_dir="${1:-/usr/local/lib}"
dest="$dest_dir/libpowersync_$arch.so"
url="https://github.com/powersync-ja/powersync-sqlite-core/releases/download/$version/libpowersync_$arch.linux.so"

mkdir -p "$dest_dir"
download="$(mktemp "$dest_dir/.libpowersync.XXXXXX")"
trap 'rm -f "$download"' EXIT
curl -fsSL --retry 3 -o "$download" "$url"
echo "$sha256  $download" | sha256sum --check --quiet -
chmod 0644 "$download"
mv "$download" "$dest"
echo "$dest"
