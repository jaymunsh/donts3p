# ADR 0003: Privileged Helper Approval

- **Status:** Not approved — fail closed
- **Decision:** Ship the assertion-only baseline without closed-lid support.

## Entry criteria

This ADR cannot be approved until ADR 0001 contains passing capability and restoration evidence and ADR 0002 contains an accepted privileged-boundary design and negative-test evidence.

## Required independent approvals

| Reviewer | Name | Date | Decision | Evidence references |
| --- | --- | --- | --- | --- |
| Architect | | | Pending | |
| Security reviewer | | | Pending | |

Architect and security approval are distinct. A missing, conditional, expired, or rejected approval means no privileged source, protocol, daemon, installer, or release may be created. There is no fallback to a generic command runner, SIP weakening, or Gatekeeper bypass.

## Approval decision

Only both named reviewers may change this status to Approved after validating the entry criteria, threat model, recovery and uninstall behavior, and release artifacts. Until then, the product remains shippable as the unprivileged baseline and explicitly reports closed-lid support as unavailable.
