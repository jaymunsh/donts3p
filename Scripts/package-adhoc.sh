#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
release_dir="$repo_root/release"
archive_path="$release_dir/donts3p-macos-arm64.zip"

app_path="$("$repo_root/Scripts/assemble-app.sh")"
"$repo_root/Scripts/verify-release.sh" "$app_path"

rm -f "$archive_path"
mkdir -p "$release_dir"
ditto -c -k --norsrc --keepParent "$app_path" "$archive_path"
"$repo_root/Scripts/verify-release.sh" "$archive_path"
printf '%s\n' "$archive_path"
