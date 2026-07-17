# Baseline Lifecycle Integration Specification

Run on macOS 14+ Apple Silicon with a fresh user account where practical. The baseline must not prevent screen lock or display sleep.

| ID | Scenario | Expected result |
| --- | --- | --- |
| L1 | Normal launch with no prior intent | Lock winner persists enabled intent, creates marker, registers recovery agent, and obtains a user-idle system-sleep assertion. |
| L2 | Inspect active assertion | Green only when the current process owns a matching `PreventUserIdleSystemSleep` assertion sampled within 35 seconds; query errors, missing, or mismatched assertions are red. |
| L3 | Lock/display behavior while active | Screen lock and display sleep both continue to work. No display or lock prevention assertion is requested. |
| L4 | Normal contender loses lock while owner is off | Same-UID authenticated `enableAndActivate` receives typed success and the owner completes the full enable transaction. |
| L5 | Recovery contender loses lock | It exits without socket traffic or intent, marker, assertion, or agent mutation. |
| L6 | Socket adversaries | Wrong-UID, malformed, unauthenticated, and timed-out requests fail without state changes. |
| L7 | Explicit off | False intent is persisted before marker removal, agent reconciliation, and assertion release. A final owned assertion after retries produces terminal diagnostic and GUI exit; absent ID completes neutral. |
| L8 | Assertion failures | Creation retries at 1, 5, 30 seconds then five minutes while desired intent remains true; state remains red until a current matching sample. |
| L9 | Battery state | Launching on battery and AC-to-battery transition each warn once per boot; same-boot relaunch does not duplicate; AC clears the persisted warning; reboot permits one new warning. |
| L10 | False recovery state | Missing marker or false intent makes the supervisor exit 0 and launchd does not restart it. |
| L11 | Active recovery state | A valid marker/intent starts the supervisor. Existing GUI lock yields zero recovery opens; GUI crash yields exactly one same-boot recovery open. |
| L12 | Lease boundaries | Valid same-boot monotonic lease suppresses duplicate opens. Malformed lease, expired deadline, boot-ID change, and wall-clock jump are stale and removed before one new attempt. |
| L13 | Recovery fault handling | Supervisor crashes before open, after open, and after GUI lock do not duplicate a recovery open before lease expiry. Failed lock acquisition retries at +1/+5/+30 seconds then records red `recovery-degraded`. |
| L14 | Degraded clearing | A verified lock-owning normal/recovery sample or explicit off clears recovery-degraded; mere launch does not. |
| L15 | Failed unregister re-arm | Off with failed unregister followed by normal enable and GUI crash produces exactly one recovery open in that GUI session. |
| L16 | Supervisor lifetime | A recovered GUI survives supervisor clean exit, crash, unregister, and explicit off long enough to release its assertion and finish its own cleanup. |
