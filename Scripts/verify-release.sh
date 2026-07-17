#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
release_input="${1:-$repo_root/build/donts3p.app}"
work_dir=""

cleanup() {
    if [[ -n "$work_dir" ]]; then
        rm -rf "$work_dir"
    fi
}
trap cleanup EXIT

if [[ -d "$release_input" && "${release_input##*/}" == "donts3p.app" ]]; then
    app_path="$release_input"
elif [[ -f "$release_input" && "${release_input##*.}" == "zip" ]]; then
    /usr/bin/python3 - "$release_input" <<'PY'
import posixpath
import sys
import zipfile

archive_path = sys.argv[1]

try:
    with zipfile.ZipFile(archive_path) as archive:
        entries = archive.infolist()
except (OSError, zipfile.BadZipFile) as error:
    raise SystemExit(f"Unable to read ZIP archive: {error}")

if not entries:
    raise SystemExit("ZIP archive has no entries.")

seen_paths = set()
for entry in entries:
    name = entry.orig_filename

    if not name:
        raise SystemExit("ZIP archive contains an empty entry name.")
    if "\x00" in name or "\\" in name:
        raise SystemExit(f"ZIP archive contains an ambiguous entry path: {name!r}")
    if name.startswith("/"):
        raise SystemExit(f"ZIP archive contains an absolute entry path: {name!r}")
    if any(ord(character) < 32 or ord(character) == 127 for character in name):
        raise SystemExit(f"ZIP archive contains an ambiguous entry path: {name!r}")

    is_directory = name.endswith("/")
    components = name[:-1].split("/") if is_directory else name.split("/")
    if not components or any(component in ("", ".", "..") for component in components):
        raise SystemExit(f"ZIP archive contains an invalid entry path: {name!r}")

    normalized_path = posixpath.normpath(name[:-1] if is_directory else name)
    if normalized_path != "donts3p.app" and not normalized_path.startswith("donts3p.app/"):
        raise SystemExit(f"ZIP archive entry escapes donts3p.app: {name!r}")
    if normalized_path in seen_paths:
        raise SystemExit(f"ZIP archive contains duplicate entry path: {name!r}")
    seen_paths.add(normalized_path)
PY

    archive_entries="$(unzip -Z1 "$release_input")"

    work_dir="$(mktemp -d)"
    unzip -qq "$release_input" -d "$work_dir"
    shopt -s dotglob nullglob
    extracted_root_entries=("$work_dir"/*)
    shopt -u dotglob nullglob
    [[ "${#extracted_root_entries[@]}" -eq 1 ]]
    [[ "${extracted_root_entries[0]}" == "$work_dir/donts3p.app" ]]
    app_path="$work_dir/donts3p.app"
else
    printf 'Expected donts3p.app or a .zip archive: %s\n' "$release_input" >&2
    exit 64
fi

[[ -d "$app_path" ]]
[[ -f "$app_path/Contents/Info.plist" ]]
[[ -x "$app_path/Contents/MacOS/donts3p" ]]
[[ -x "$app_path/Contents/Library/Helpers/donts3pRecoverySupervisor" ]]
[[ -f "$app_path/Contents/Library/LaunchAgents/org.donts3p.recovery.plist" ]]
[[ -f "$app_path/Contents/Resources/LICENSE" ]]
[[ -f "$app_path/Contents/Resources/SourceURL.txt" ]]

verify_launch_agent_contract() {
    local plist_path="$1"
    local prohibited_key
    local line
    local key

    while IFS= read -r line; do
        case "$line" in
            "    "[![:space:]]*" = "*)
                key="${line#    }"
                key="${key%% = *}"
                case "$key" in
                    Label|BundleProgram|RunAtLoad|KeepAlive|ProcessType) ;;
                    *)
                        printf 'LaunchAgent contains disallowed top-level key: %s\n' "$key" >&2
                        return 1
                        ;;
                esac
                ;;
            "        "[![:space:]]*" = "*)
                key="${line#        }"
                key="${key%% = *}"
                if [[ "$key" != "SuccessfulExit" ]]; then
                    printf 'LaunchAgent contains disallowed nested key: %s\n' "$key" >&2
                    return 1
                fi
                ;;
        esac
    done < <(/usr/libexec/PlistBuddy -c 'Print' "$plist_path")

    for prohibited_key in Program ProgramArguments PathState UserName GroupName RootDirectory WorkingDirectory Umask InitGroups; do
        if /usr/libexec/PlistBuddy -c "Print :$prohibited_key" "$plist_path" >/dev/null 2>&1; then
            printf 'LaunchAgent contains prohibited key: %s\n' "$prohibited_key" >&2
            return 1
        fi
    done

    if /usr/libexec/PlistBuddy -c 'Print' "$plist_path" | while IFS= read -r line; do
        if [[ "$line" == *'~'* || "$line" == *'$'* ]]; then
            exit 1
        fi
    done; then
        return 0
    fi

    printf 'LaunchAgent contains a shell or home-directory expansion.\n' >&2
    return 1
}

plutil -lint "$app_path/Contents/Info.plist"
plutil -lint "$app_path/Contents/Library/LaunchAgents/org.donts3p.recovery.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist")" == "org.donts3p" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app_path/Contents/Info.plist")" == "14.0" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$app_path/Contents/Library/LaunchAgents/org.donts3p.recovery.plist")" == "org.donts3p.recovery" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :BundleProgram' "$app_path/Contents/Library/LaunchAgents/org.donts3p.recovery.plist")" == "Contents/Library/Helpers/donts3pRecoverySupervisor" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :RunAtLoad' "$app_path/Contents/Library/LaunchAgents/org.donts3p.recovery.plist")" == "true" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :KeepAlive:SuccessfulExit' "$app_path/Contents/Library/LaunchAgents/org.donts3p.recovery.plist")" == "false" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :ProcessType' "$app_path/Contents/Library/LaunchAgents/org.donts3p.recovery.plist")" == "Interactive" ]]
verify_launch_agent_contract "$app_path/Contents/Library/LaunchAgents/org.donts3p.recovery.plist"

for executable in "$app_path/Contents/MacOS/donts3p" "$app_path/Contents/Library/Helpers/donts3pRecoverySupervisor"; do
    [[ "$(lipo -archs "$executable")" == "arm64" ]]
    codesign --verify --deep --strict --verbose=2 "$executable"
done
codesign --verify --deep --strict --verbose=2 "$app_path"

if [[ -f "$release_input" && "${release_input##*.}" == "zip" ]]; then
    [[ "$archive_entries" == *"donts3p.app/Contents/Info.plist"* ]]
    [[ "$archive_entries" == *"donts3p.app/Contents/MacOS/donts3p"* ]]
    [[ "$archive_entries" == *"donts3p.app/Contents/Library/Helpers/donts3pRecoverySupervisor"* ]]
    [[ "$archive_entries" == *"donts3p.app/Contents/Library/LaunchAgents/org.donts3p.recovery.plist"* ]]
    [[ "$archive_entries" == *"donts3p.app/Contents/Resources/LICENSE"* ]]
    [[ "$archive_entries" == *"donts3p.app/Contents/Resources/SourceURL.txt"* ]]
fi

printf 'Verified ad-hoc arm64 release: %s\n' "$release_input"
