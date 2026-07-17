#!/bin/bash
set -euo pipefail

uid="$(id -u)"
label="org.donts3p.recovery"
legacy_label="org.dontsleep.recovery"
state_dir="$HOME/Library/Application Support/org.donts3p"
legacy_state_dir="$HOME/Library/Application Support/org.dontsleep"
run_lock="$state_dir/run.lock"
legacy_run_lock="$legacy_state_dir/run.lock"
activation_socket="$state_dir/activate.sock"
legacy_activation_socket="$legacy_state_dir/activate.sock"

system_sleep_override_snapshot="$state_dir/system-sleep-override.json"
hold_run_locks() {
    /usr/bin/python3 - "$run_lock" "$legacy_run_lock" "$0" "$@" <<'PY'
import fcntl
import os
import subprocess
import sys

current_lock_path, legacy_lock_path, script, *arguments = sys.argv[1:]
try:
    descriptors = []
    # Always acquire current before legacy so concurrent uninstalls cannot deadlock.
    for lock_path in (current_lock_path, legacy_lock_path):
        os.makedirs(os.path.dirname(lock_path), mode=0o700, exist_ok=True)
        descriptor = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.lockf(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        descriptors.append(descriptor)
except OSError:
    sys.exit(75)

try:
    result = subprocess.run([script, "--lock-held", *arguments])
except OSError:
    sys.exit(76)
sys.exit(result.returncode)
PY
}

if [[ "${1:-}" != "--lock-held" ]]; then
    if hold_run_locks "$@"; then
        exit 0
    else
        status=$?
        if [[ "$status" -eq 75 ]]; then
            printf 'Cannot acquire donts3p or legacy GUI advisory lock; refusing to modify state.\n' >&2
        fi
        exit "$status"
    fi
fi
shift

activation_socket_is_live() {
    local socket_path="$1"
    [[ -S "$socket_path" ]] || return 1

    perl -MSocket=AF_UNIX,SOCK_STREAM,pack_sockaddr_un -e '
        socket my $socket, AF_UNIX, SOCK_STREAM, 0 or exit 2;
        connect $socket, pack_sockaddr_un($ARGV[0]) or exit 1;
        exit 0;
    ' "$socket_path"
}

current_socket_status=1
legacy_socket_status=1
if activation_socket_is_live "$activation_socket"; then
    current_socket_status=0
else
    current_socket_status=$?
fi
if activation_socket_is_live "$legacy_activation_socket"; then
    legacy_socket_status=0
else
    legacy_socket_status=$?
fi

if [[ "$current_socket_status" -gt 1 || "$legacy_socket_status" -gt 1 ]]; then
    printf 'Cannot determine donts3p or legacy activation socket ownership; refusing to modify state.\n' >&2
    exit 1
fi
if [[ "$current_socket_status" -eq 0 || "$legacy_socket_status" -eq 0 ]]; then
    printf 'donts3p or legacy application GUI activation socket is active; quit it before uninstalling.\n' >&2
    exit 1
fi
if [[ -f "$system_sleep_override_snapshot" ]]; then
    printf 'A donts3p Labs system-sleep override is still recorded. Restore it from the app before uninstalling.\n' >&2
    printf 'Emergency fallback: sudo /usr/bin/pmset -a disablesleep 0\n' >&2
    exit 1
fi

for recovery_label in "$label" "$legacy_label"; do
    if launchctl print "gui/$uid/$recovery_label" >/dev/null 2>&1; then
        launchctl bootout "gui/$uid/$recovery_label"
    fi
    if launchctl print "gui/$uid/$recovery_label" >/dev/null 2>&1; then
        printf 'Recovery supervisor is still loaded: %s\n' "$recovery_label" >&2
        exit 1
    fi
done

# Remove only the baseline's fixed user-owned state files. Leave unknown files intact.
# Keep each run.lock in place until all other shared state in its namespace is gone:
# the held descriptors protect those pathnames until they are unlinked last.
for cleanup_dir in "$state_dir" "$legacy_state_dir"; do
    for state_file in intent.json recovery.enabled recovery.lease recovery.degraded activate.sock; do
        rm -f "$cleanup_dir/$state_file"
    done
done
rm -f "$legacy_run_lock"
rm -f "$run_lock"
