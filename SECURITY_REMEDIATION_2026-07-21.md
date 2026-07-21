# Security Remediation - 2026-07-21

This document records the remediation of the findings in
`Nexaloid_安全审计报告_2026-07-20.md`, audited against commit
`6f2554c289881d7aca7372ee90b7db1267c5922d`.

## Finding status

| Finding | Status | Remediation |
|---|---|---|
| NX-SEC-001 | Fixed | Engine construction now uses an error-union helper with complete allocator-owned cleanup and failure-injection coverage. |
| NX-SEC-002 | Fixed | Batch creation tracks spawned/joined workers, joins partial starts on failure, and caps workers at 64. |
| NX-SEC-003 | Fixed | Rust exposes an owned `Config`; raw `NxConfig` construction moved to documented `unsafe from_raw_config`. |
| NX-SEC-004 | Fixed | Python publishes engines only after full initialization and frees local primary/HMM candidates on every failure. |
| NX-SEC-005 | Fixed | Recursive `literal_sequence` backtracking was replaced by bounded dynamic programming with a shared per-segment state budget. |
| NX-SEC-006 | Fixed | Python serializes every native call and close operation with an `RLock`; close is idempotent. |
| NX-SEC-007 | Fixed | Text/NXDICT loaders enforce size/count limits, checked arithmetic, DAT invariants, UTF-8/finite scores, exact consumption, and transactional user-dictionary replacement. |
| NX-SEC-008 | Fixed | Python and C++ callbacks capture and rethrow host exceptions; Node checks every fallible N-API operation and rejects partial results. |
| NX-SEC-009 | Fixed | Remote Actions are pinned to full SHAs, Zig 0.16.0 archives are SHA-256 verified before extraction, and CI enforces both policies. |
| NX-SEC-010 | Fixed | Release tooling is pinned and tag releases produce unified checksums, an SPDX 2.3 SBOM, build provenance, and SBOM attestations. |
| NX-SEC-011 | Fixed | ABI entry points reject byte lengths, character counts, and batch counts that cannot be represented by `u32`. |
| NX-SEC-012 | Fixed | Text dictionaries are read with a 512 MiB file bound and 1 MiB line bound; long lines fail instead of splitting. |
| NX-SEC-013 | Fixed | Runtime, text, binary, and builder paths reject empty words, non-finite scores, overlong words, and invalid builder rows. |
| NX-SEC-014 | Fixed | Python domain identifiers are whitelisted and resolved paths are containment-checked, including symlink targets. |

Additional review findings were also closed: Go now serializes `Close` against
all native calls and returns `ErrTokenizerClosed`; Python `CFUNCTYPE` exceptions
are propagated instead of being printed and swallowed; Node constructor and
method N-API failures now use the same checked path as callbacks.

## Security limits

- One input and ABI length/count fields: at most `UINT32_MAX` where offsets or indexes are `u32`.
- Batch workers: at most 64.
- Custom rules JSON: at most 1 MiB.
- Dictionary file: at most 512 MiB; text line: at most 1 MiB.
- NXDICT: at most 4,000,000 entries and 16,000,000 DAT states.
- Custom matching: 1,000,000 state transitions per segment.

The C ABI thread and ownership contract is documented in
`core/include/nexaloid.h`. Python and Go deliberately serialize one high-level
instance; use multiple instances when parallel calls are required.

## Release operations

Repository-environment required reviewers, protected tags, and organization
rulesets are GitHub settings and cannot be enforced by committed workflow code.
Release administrators must enable them for the production environment. The
committed controls use least-privilege job permissions, immutable Action SHAs,
verified Zig downloads, pinned Python build tools, checksums, SBOM, and GitHub
artifact attestations.
