# ADR 0002: Ad-Hoc Privileged Boundary

- **Status:** Superseded for the one-shot Labs path by ADR 0004
- **Decision:** No persistent privileged helper or daemon is shipped. ADR 0004 permits only a fixed, administrator-authorized one-shot `pmset` operation with exact restoration.

## Required decision record

Before implementation, compare an unsigned-compatible one-shot authorization path with a persistent daemon. Select one endpoint and transport, then document all of the following with review evidence:

1. Audit-token validation plus pinned client code-hash validation; authorization-right acquisition, evidence lifetime, nonce, replay defense, and expiry.
2. Root-owned fixed paths, owners, modes, symlink defenses, trust-record location and format, protocol-version negotiation, and nondisclosing errors.
3. Daemon lifetime; atomic update and trust rotation; downgrade resistance; and installation, update, restore, and uninstall ordering.
4. Threat model and negative tests for unauthorized callers, wrong audit token/hash, replay, malformed/oversized/unknown messages, disconnects, timeouts, symlinks, archive ownership/modes, update/downgrade, multi-user contention, and crash/restore paths.

The implementation, if approved, may expose only `capabilities`, `status`, `applyExactProfile`, `renewLease`, and `restoreOwnedProfile`. It must not accept caller-selected paths, values, tools, keys, or commands.

## Journal invariant `I`

A valid-schema record enters `I` only for an impossible field invariant: original equals target; phase is missing or invalid; a restored record retains owned authority; or the phase/value tuple is impossible after the persisted operation. `I` performs no mutation, blocks uninstall, and retains evidence for remediation. Corrupt or unknown schemas are not guessed and also block destructive cleanup.

## Approval evidence

Attach the selected design, threat-model review, test evidence, authorization UX evidence, recovery/update/uninstall walkthroughs, and security review. Until all are accepted, the baseline UI must state that closed-lid support is unavailable.
