# Peripheral contracts: open items

## P3 OracleAdminGuard: second Safe can take the guardian role

- **Gap.** `setGuardian` is callable by the Oracle Safe and by the second Safe, with no delay. A compromised second Safe can instantly appoint itself guardian, then cancel its own queued replacement.
- **Mitigation today.** The Oracle Safe can switch the guardian back, so the outcome is a race between the two Safes.
- **Candidate fixes.** Limit `setGuardian` to the Oracle Safe, or forbid the second Safe from appointing itself.
- **Status.** Deferred, to revisit.
