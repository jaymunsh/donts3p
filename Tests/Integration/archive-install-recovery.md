# Archive, Installation, and Recovery Integration Specification

Run these checks against the release archive on macOS 14+ Apple Silicon.

| ID | Scenario | Expected result |
| --- | --- | --- |
| R1 | Build graph | `Package.swift` exposes `DontSleepShared`, `donts3p`, and `donts3pRecoverySupervisor` and declares macOS 14 minimum. |
| R2 | App layout | Archive root contains only `donts3p.app`; the bundle contains Info.plist, GUI executable, supervisor helper, embedded LaunchAgent plist, LICENSE, and SourceURL.txt at their fixed paths. |
| R3 | Architecture and signature | Both Mach-O executables are arm64 only. Nested executables and outer app pass strict ad-hoc signature verification. |
| R4 | Plist contract | Bundle ID is `org.donts3p`; LaunchAgent label is `org.donts3p.recovery`; BundleProgram is `Contents/Library/Helpers/donts3pRecoverySupervisor`; RunAtLoad is true; KeepAlive.SuccessfulExit is false; ProcessType is Interactive. |
| R5 | Prohibited LaunchAgent configuration | The embedded plist has no Program, ProgramArguments, PathState, shell path, tilde, environment expansion, root-only key, or mutable bundle path. |
| R6 | Source and license | The archive includes the MIT license and source URL. The source URL resolves to the public project repository before publication. |
| R7 | Gatekeeper guidance | Documentation instructs a per-app Finder Control-click Open or System Settings approval and never asks users to globally disable Gatekeeper or run `spctl --master-disable`. |
| R8 | Install and first launch | Copy the bundle to `/Applications`; launch it; verify only the current user's recovery service is registered and no privileged helper or daemon is installed. |
| R9 | Login/reboot recovery | Enable, reboot, log in, and confirm one recovery launch only when durable intent and marker remain true. No pre-login continuity is required. |
| R10 | Moved/deleted app cleanup | `launchctl bootout gui/$UID/org.donts3p.recovery` accepts an absent label, verifies the fixed label is absent, and never follows a mutable bundle path. Upgrade cleanup also unregisters legacy `org.dontsleep.recovery` before removing its recovery marker. |
| R11 | User uninstall | `Scripts/uninstall-user.sh` acquires current then legacy `run.lock` before inspecting sockets or recovery registrations, removes current and legacy fixed recovery registrations and known user state only, leaves unknown files intact, and does not delete the application bundle. |
| R12 | Uninstall lock handoff | The uninstall holds both namespace locks until cleanup. It removes every other fixed state file in each namespace before unlinking that namespace's `run.lock`; GUI startup at either unlink boundary cannot create a split lock inode whose socket is then removed. |
| R13 | Closed-lid boundary | Release contains no privileged helper source, daemon, installer, protocol, or global power mutation. ADR 0003 remains unapproved; UI and documentation describe closed-lid support as unavailable. |
| R14 | Menu-bar status icon | The menu-bar label renders a large `Z` with superscript `3` (`Z³`) and a lower-right circled checkmark only for a freshly observed active assertion. Inactive, stale, degraded, and failed observations render a lower-right circled X. Both render distinctly in monochrome and expose `donts3p: sleep prevention active` or `donts3p: sleep prevention inactive` accessibility labels; opening the menu shows `donts3p` and the current status. |
## Executable artifact checks

Run the verifier against both distributable forms. For an archive, it parses every ZIP central-directory entry before extraction, including the first entry. Entries must be `donts3p.app` or descendants with canonical slash-separated components. It rejects absolute paths, empty, dot, dot-dot, backslash, control-character, duplicate, and normalized out-of-bundle paths; a trailing slash is permitted only as the directory-entry marker. After extraction, the temporary root must contain exactly `donts3p.app` and no extra or hidden entries. It rejects AppleDouble `__MACOSX/`, `.DS_Store`, and any other archive root. It rejects any LaunchAgent top-level key other than `Label`, `BundleProgram`, `RunAtLoad`, `KeepAlive`, and `ProcessType`, and rejects nested `KeepAlive` keys other than `SuccessfulExit`.

```bash
Scripts/verify-release.sh build/donts3p.app
Scripts/verify-release.sh path/to/donts3p.zip
```
Exercise archive traversal rejection with strict shell semantics. Each fixture fails during pre-extraction ZIP validation, so it does not require a signed bundle payload.

```bash
set -euo pipefail

fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT
case_number=0
for entry in \
    '' \
    '/donts3p.app/Contents/Info.plist' \
    'donts3p.app//Contents/Info.plist' \
    'donts3p.app/./Contents/Info.plist' \
    'donts3p.app/../extra' \
    'donts3p.app\Contents\Info.plist' \
    'extra'; do
    ((case_number += 1))
    archive="$fixture_dir/$case_number.zip"
    /usr/bin/python3 - "$archive" "$entry" <<'PY'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1], "w") as archive:
    archive.writestr(sys.argv[2], b"malicious")
PY
    if Scripts/verify-release.sh "$archive"; then
        printf 'Verifier accepted unsafe ZIP entry: %s\n' "$entry" >&2
        exit 1
    fi
done
```

Exercise the uninstall state contract in an isolated home directory. The fixed files must be removed and the unknown file must remain.

```bash
fixture_home="$(mktemp -d)"
trap 'rm -rf "$fixture_home"' EXIT
state_dir="$fixture_home/Library/Application Support/org.donts3p"
legacy_state_dir="$fixture_home/Library/Application Support/org.dontsleep"
mkdir -p "$state_dir" "$legacy_state_dir"
touch "$state_dir/intent.json" "$state_dir/recovery.enabled" "$state_dir/recovery.lease" \
    "$state_dir/recovery.degraded" "$state_dir/run.lock" "$state_dir/activate.sock" "$state_dir/unknown"
touch "$legacy_state_dir/intent.json" "$legacy_state_dir/recovery.enabled" "$legacy_state_dir/recovery.lease" \
    "$legacy_state_dir/recovery.degraded" "$legacy_state_dir/run.lock" "$legacy_state_dir/activate.sock" "$legacy_state_dir/unknown"
HOME="$fixture_home" Scripts/uninstall-user.sh
for cleanup_dir in "$state_dir" "$legacy_state_dir"; do
    for state_file in intent.json recovery.enabled recovery.lease recovery.degraded run.lock activate.sock; do
        [[ ! -e "$cleanup_dir/$state_file" ]]
    done
done
[[ ! -e "$state_dir/run.lock" ]]
[[ -e "$state_dir/unknown" && -e "$legacy_state_dir/unknown" ]]
```
Verify that a live current or legacy GUI advisory lock rejects uninstall before bootout or any state mutation. The lock holder uses Darwin's POSIX `lockf` interface rather than an ABI-dependent `struct flock` buffer; while it is held, every known state file in both namespaces must remain.

```bash
touch "$state_dir/intent.json" "$state_dir/recovery.enabled" "$state_dir/recovery.lease" \
    "$state_dir/recovery.degraded" "$state_dir/run.lock" "$state_dir/activate.sock"
touch "$legacy_state_dir/intent.json" "$legacy_state_dir/recovery.enabled" "$legacy_state_dir/recovery.lease" \
    "$legacy_state_dir/recovery.degraded" "$legacy_state_dir/run.lock" "$legacy_state_dir/activate.sock"
/usr/bin/python3 - "$state_dir/run.lock" <<'PY' &
import fcntl
import sys
import time

with open(sys.argv[1], "r+") as lock_file:
    fcntl.lockf(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
    time.sleep(30)
PY
lock_pid=$!
if HOME="$fixture_home" Scripts/uninstall-user.sh; then
    exit 1
fi
for cleanup_dir in "$state_dir" "$legacy_state_dir"; do
    for state_file in intent.json recovery.enabled recovery.lease recovery.degraded run.lock activate.sock; do
        [[ -e "$cleanup_dir/$state_file" ]]
    done
done
[[ -e "$state_dir/unknown" && -e "$legacy_state_dir/unknown" ]]
kill "$lock_pid"
wait "$lock_pid" || true
```
Verify the unlink boundaries do not permit a second GUI to split either lock inode before socket cleanup: arrange blocked GUI startup to attempt creation of each namespace's `run.lock` immediately after its `activate.sock` is removed; it must either observe the held original lock before cleanup completes or start only after cleanup has completed. Each `run.lock` must be the final removed fixed-state pathname in its namespace, with no subsequent shared-state mutation.
Recreate the fixed files in both namespaces, then exercise legacy lock contention. A held legacy lock must prevent cleanup of either namespace, proving that uninstall does not acquire only the current lock.
```bash
touch "$state_dir/intent.json" "$state_dir/recovery.enabled" "$state_dir/recovery.lease" \
    "$state_dir/recovery.degraded" "$state_dir/run.lock" "$state_dir/activate.sock"
touch "$legacy_state_dir/intent.json" "$legacy_state_dir/recovery.enabled" "$legacy_state_dir/recovery.lease" \
    "$legacy_state_dir/recovery.degraded" "$legacy_state_dir/run.lock" "$legacy_state_dir/activate.sock"
/usr/bin/python3 - "$legacy_state_dir/run.lock" <<'PY' &
import fcntl
import sys
import time

with open(sys.argv[1], "r+") as lock_file:
    fcntl.lockf(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
    time.sleep(30)
PY
legacy_lock_pid=$!
if HOME="$fixture_home" Scripts/uninstall-user.sh; then
    exit 1
fi
for cleanup_dir in "$state_dir" "$legacy_state_dir"; do
    for state_file in intent.json recovery.enabled recovery.lease recovery.degraded run.lock activate.sock; do
        [[ -e "$cleanup_dir/$state_file" ]]
    done
done
[[ -e "$state_dir/unknown" && -e "$legacy_state_dir/unknown" ]]
kill "$legacy_lock_pid"
wait "$legacy_lock_pid" || true
```
