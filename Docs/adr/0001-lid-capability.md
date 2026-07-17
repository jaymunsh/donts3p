# ADR 0001: Closed-Lid Capability Evidence

- **Status:** Proposed — fail closed
- **Decision:** The shipped baseline has no closed-lid support and makes no global power-setting change.

## Gate

Closed-lid work may proceed only after this document records passing, reproducible evidence on every intended hardware and OS combination. Missing, ambiguous, failed, or unrestorable evidence is a failure; the feature remains omitted.

Record for each run: Mac model and identifier, macOS build, boot ID, AC/battery state, external-display state, FileVault state, login state, test date, operator, and exact app revision.

| Check | Before | During candidate | After restore | Result/evidence |
| --- | --- | --- | --- | --- |
| Screen lock remains available | | | | |
| Display sleep remains available | | | | |
| Lid-close behavior | | | | |
| Wake/recovery behavior | | | | |
| Thermal behavior | | | | |
| Battery behavior | | | | |
| Exact setting readback | | | | |
| Original setting restored | | | | |

## Candidate-only experiment

The only candidate command is a direct fixed executable invocation, never a shell:

```swift
Process(executableURL: URL(fileURLWithPath: "/usr/bin/pmset"), arguments: ["-a", "disablesleep", "1"])
// inverse: ["-a", "disablesleep", "0"]
```

Read `/usr/bin/pmset -g` with UTF-8 stdout capped at 64 KiB. Accept only zero exit status, empty stderr, and exactly one line matching `^[[:space:]]*SleepDisabled[[:space:]]+(0|1)[[:space:]]*$`. Missing, duplicate, malformed, oversized, or non-UTF-8 output is unsupported.

Reject a candidate when original equals target, any readback or restore fails, output is ambiguous, or it violates screen-lock or display-sleep constraints. Capture before, after, and restored evidence. This ADR passing does not authorize privileged code; ADR 0002 and independently approved ADR 0003 remain required.
