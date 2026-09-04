#!/usr/bin/env bash
set -euo pipefail

# Builds a compressed DMG with the standard macOS install affordance: the app
# bundle beside an /Applications symlink, with a Finder icon layout (.DS_Store)
# so the mounted volume opens showing where to drag the app.
#
# The layout ships as the static asset apps/macos/dmg-layout/.DS_Store instead
# of being generated through Finder automation at package time: modern Finder
# does not reliably persist view options for mounted volumes, and a static file
# keeps the release build deterministic. The asset was generated once by
# positioning "Holon.app" and the Applications symlink in Finder, with the
# symlink coordinates patched in afterwards because Finder refuses to persist
# positions for symlink items.

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <Holon.app> <output.dmg>" >&2
  exit 2
fi

app_bundle="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
output_dmg="$2"
app_name="$(basename "$app_bundle")"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
layout_ds_store="$repo_root/apps/macos/dmg-layout/.DS_Store"

[[ -d "$app_bundle" ]] || {
  echo "app bundle is missing: $app_bundle" >&2
  exit 1
}

[[ -f "$layout_ds_store" ]] || {
  echo "DMG layout asset is missing: $layout_ds_store" >&2
  exit 1
}

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/holon-dmg.XXXXXX")"
mounted_volume=""

cleanup() {
  if [[ -n "$mounted_volume" ]]; then
    hdiutil detach "$mounted_volume" >/dev/null 2>&1 || true
  fi
  rm -rf "$work_dir"
}
trap cleanup EXIT

staging_dir="$work_dir/staging"
mkdir -p "$staging_dir"
ditto "$app_bundle" "$staging_dir/$app_name"
ln -s /Applications "$staging_dir/Applications"
cp "$layout_ds_store" "$staging_dir/.DS_Store"

rm -f "$output_dmg"
hdiutil create -quiet -volname Holon -srcfolder "$staging_dir" -ov \
  -format UDZO "$output_dmg"

# Verify the install affordance survived packaging instead of discovering a
# regression in the released artifact.
attach_output="$(hdiutil attach -readonly -nobrowse -noautoopen "$output_dmg" 2>/dev/null)"
mounted_volume="$(printf '%s\n' "$attach_output" | sed -n 's|.*\(/Volumes/.*\)$|\1|p' | tail -1)"
[[ -d "$mounted_volume" ]] || {
  echo "failed to locate the mounted output DMG volume" >&2
  exit 1
}
[[ -d "$mounted_volume/$app_name" ]] || {
  echo "output DMG is missing $app_name" >&2
  exit 1
}
[[ -L "$mounted_volume/Applications" ]] || {
  echo "output DMG is missing the /Applications symlink" >&2
  exit 1
}
[[ -f "$mounted_volume/.DS_Store" ]] || {
  echo "output DMG is missing the Finder window layout" >&2
  exit 1
}
cmp -s "$layout_ds_store" "$mounted_volume/.DS_Store" || {
  echo "output DMG Finder layout does not match $layout_ds_store" >&2
  exit 1
}
hdiutil detach "$mounted_volume" >/dev/null 2>&1 || true
mounted_volume=""

echo "$output_dmg"
