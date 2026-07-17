#!/bin/bash
set -euo pipefail

printf 'This emergency fallback enables normal macOS system sleep for every power profile.\n'
printf 'It does not restore a custom per-profile value; use donts3p → Restore system sleep setting when possible.\n'
/usr/bin/osascript -e 'do shell script "/usr/bin/pmset -a disablesleep 0" with administrator privileges'

if ! settings="$(/usr/bin/pmset -g custom)"; then
    printf 'Restore verification failed: unable to read macOS power settings.\n' >&2
    exit 1
fi
if printf '%s\n' "$settings" | /usr/bin/grep -Eq '^[[:space:]]*disablesleep[[:space:]]+1([[:space:]]*)$'; then
    printf 'Restore verification failed: at least one profile still has disablesleep 1.\n' >&2
    exit 1
fi

printf 'Normal system sleep is enabled for all power profiles.\n'
