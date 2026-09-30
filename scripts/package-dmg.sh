#!/bin/bash
# Preserve the original Augment installer artwork, Finder layout and volume identity.
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
app="${1:?Usage: package-dmg.sh /path/to/Augment.app /path/to/output.dmg}"
output="${2:?Provide the output DMG path}"
[[ -d "$app/Contents" ]] || { echo 'Application bundle not found' >&2; exit 1; }
codesign --verify --deep --strict "$app"
mkdir -p "$repo_dir/build" "$(dirname "$output")"
work="$(mktemp -d "$repo_dir/build/dmg-package.XXXXXX")"
mount_dir="$work/mount"
mounted=0
cleanup() {
    if [[ "$mounted" == 1 ]]; then
        hdiutil detach "$mount_dir" >/dev/null || return
    fi
    rm -rf "$work"
}
trap cleanup EXIT

template="$repo_dir/build/Augment-1.0.6.dmg"
if [[ ! -f "$template" ]]; then
    curl --fail --location --output "$work/template.dmg" \
        'https://github.com/anilipeksumer/Augment_MacOS/releases/download/v1.0.6/Augment-1.0.6.dmg'
    template="$work/template.dmg"
fi
expected='e85c6330dda3a77152085b84e7ed23ce992852726b78c7630e077c32a9e4e644'
[[ "$(shasum -a 256 "$template" | awk '{print $1}')" == "$expected" ]] || {
    echo 'Original installer checksum mismatch; refusing to change the layout' >&2
    exit 1
}

# A filesystem clone preserves .DS_Store's background alias, icon positions,
# window size, HFS+ volume name and Finder metadata. A fresh -srcfolder DMG does not.
hdiutil convert "$template" -format UDRW -o "$work/writable.dmg" >/dev/null
mkdir "$mount_dir"
hdiutil attach -nobrowse -noautoopen -mountpoint "$mount_dir" "$work/writable.dmg" >/dev/null
mounted=1
[[ -d "$mount_dir/Augment.app" && -f "$mount_dir/.DS_Store" && -f "$mount_dir/.background/bg.tiff" ]]
[[ "$(readlink "$mount_dir/Applications")" == /Applications ]]
rm -rf "$mount_dir/Augment.app"
ditto "$app" "$mount_dir/Augment.app"
codesign --verify --deep --strict "$mount_dir/Augment.app"
[[ "$(shasum -a 256 "$mount_dir/.DS_Store" | awk '{print $1}')" == 'd433507d42ccef441dc20e992814c0bd35129cbc91f7ef7c9aea239d7f32417d' ]]
[[ "$(shasum -a 256 "$mount_dir/.background/bg.tiff" | awk '{print $1}')" == '228724ee37935a469a65b6a91ba6829255b6ea1cacb5e9c6857c8f6753c11eb9' ]]
hdiutil detach "$mount_dir" >/dev/null
mounted=0
hdiutil convert "$work/writable.dmg" -format UDZO -o "$work/installer.dmg" >/dev/null
mv "$work/installer.dmg" "$output"
echo "Created $output using the original Augment installer layout. Sign and notarize before publishing."
