#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
dist_dir="${1:-$project_dir/dist}"
info_plist="$project_dir/Info.plist"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")"

if [[ -n "${EXPECTED_VERSION:-}" && "$EXPECTED_VERSION" != "$version" ]]; then
  echo "Expected version $EXPECTED_VERSION, but Info.plist contains $version" >&2
  exit 1
fi

mkdir -p "$dist_dir"
"$project_dir/build-app.sh" "$dist_dir"

app_path="$dist_dir/Codex Usage Bar.app"
archive_path="$dist_dir/Codex-Usage-Bar-v$version.zip"
checksum_path="$archive_path.sha256"

plutil -lint "$app_path/Contents/Info.plist"
codesign --verify --strict "$app_path"

if [[ -e "$archive_path" ]]; then
  rm -f "$archive_path"
fi
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$archive_path"

(
  cd "$dist_dir"
  shasum -a 256 "$(basename "$archive_path")" > "$(basename "$checksum_path")"
  shasum -a 256 -c "$(basename "$checksum_path")"
)

echo "Created Codex Usage Bar $version (build $build)"
echo "$archive_path"
echo "$checksum_path"
