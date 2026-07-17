#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
configuration="release"
architecture="arm64"
build_root="$repo_root/build"
app_path="$build_root/donts3p.app"

case "$configuration" in
    debug|release) ;;
    *) printf 'Unsupported CONFIGURATION: %s\n' "$configuration" >&2; exit 64 ;;
esac
case "$architecture" in
    arm64) ;;
    *) printf 'Only arm64 builds are supported: %s\n' "$architecture" >&2; exit 64 ;;
esac

cd "$repo_root"
swift build --configuration "$configuration" --arch "$architecture" >&2
bin_path="$(swift build --configuration "$configuration" --arch "$architecture" --show-bin-path)"
rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Library/Helpers" "$app_path/Contents/Library/LaunchAgents" "$app_path/Contents/Resources"

install -m 755 "$bin_path/donts3p" "$app_path/Contents/MacOS/donts3p"
install -m 755 "$bin_path/donts3pRecoverySupervisor" "$app_path/Contents/Library/Helpers/donts3pRecoverySupervisor"
install -m 644 "$repo_root/Resources/App/Info.plist" "$app_path/Contents/Info.plist"
install -m 644 "$repo_root/Resources/App/AppIcon.icns" "$app_path/Contents/Resources/AppIcon.icns"
install -m 644 "$repo_root/Resources/LaunchAgents/org.donts3p.recovery.plist" "$app_path/Contents/Library/LaunchAgents/org.donts3p.recovery.plist"
install -m 644 "$repo_root/LICENSE" "$app_path/Contents/Resources/LICENSE"
install -m 644 "$repo_root/Resources/App/SourceURL.txt" "$app_path/Contents/Resources/SourceURL.txt"

plutil -lint "$app_path/Contents/Info.plist" >&2
plutil -lint "$app_path/Contents/Library/LaunchAgents/org.donts3p.recovery.plist" >&2
codesign --force --sign - "$app_path/Contents/MacOS/donts3p" >&2
codesign --force --sign - "$app_path/Contents/Library/Helpers/donts3pRecoverySupervisor" >&2
codesign --force --sign - "$app_path" >&2
printf '%s\n' "$app_path"
