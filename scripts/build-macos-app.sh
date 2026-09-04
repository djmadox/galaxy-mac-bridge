#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
scratch_dir="/private/tmp/galaxy-mac-bridge-macos"
output_dir="$project_dir/.build/app"
app_dir="$output_dir/MacDroid.app"

swift build \
    --package-path "$project_dir" \
    --scratch-path "$scratch_dir" \
    --configuration debug \
    --product MacDroid

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$scratch_dir/arm64-apple-macosx/debug/MacDroid" "$app_dir/Contents/MacOS/MacDroid"
cp "$project_dir/macos/Info.plist" "$app_dir/Contents/Info.plist"

xattr -cr "$app_dir"
codesign --force --deep --sign - "$app_dir"
echo "$app_dir"
