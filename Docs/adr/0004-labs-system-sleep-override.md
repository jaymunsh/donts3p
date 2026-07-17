# ADR 0004: Labs System Sleep Override

- **Status:** Accepted — experimental, opt-in, default off
- **Decision:** donts3p may offer a one-shot administrator-authorized `pmset` override in Labs. It is not supported closed-lid mode and must not be represented as a guarantee.

## Boundary

The supported default remains the unprivileged IOKit assertion. Labs is independent and changes the persistent, system-wide `disablesleep` setting only after an explicit warning and macOS administrator authentication. The app never requests, receives, or stores a password.

Only fixed Apple tools and fixed values are allowed:

- Read: `/usr/bin/pmset -g custom`
- Enable: `/usr/bin/pmset -a disablesleep 1`
- Restore: `/usr/bin/pmset -b`, `-c`, and optional `-u` with validated values `0` or `1`
- Authorization UI: `/usr/bin/osascript` with `administrator privileges`

No user-controlled path, executable, key, value, or shell fragment may enter these commands.

## Safety and restoration

1. Enabling is allowed only while AC power is connected.
2. Before mutation, persist the exact Battery, AC, and optional UPS values at `~/Library/Application Support/org.donts3p/system-sleep-override.json`.
3. Verify every profile after enabling and restoring.
4. Delete the snapshot only after exact restoration succeeds.
5. Failed mutation or verification retains the snapshot and displays an actionable diagnostic.
6. Uninstall refuses to continue while a snapshot exists.
7. `Scripts/restore-system-sleep.sh` is an emergency fallback that sets every profile to `0`; it is not an exact restoration of custom values.

## User warning

The confirmation must state that the setting persists after app exit, may increase heat and battery drain, and does not guarantee operation with a MacBook lid closed. Users should keep the Mac ventilated and must not place an active machine in a bag.

## Distribution

The one-shot authorization approach works with the free ad-hoc ZIP distribution, although Gatekeeper may require manual approval and each privileged change can prompt for administrator authentication. Developer ID signing and notarization improve installation trust but do not remove administrator authorization.
