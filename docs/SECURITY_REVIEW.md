# Source candidate security review

## Assets

- Slack, Discord, optional web-research, and future provider credentials;
- local source content, email bodies, attachments, chat history, and exports;
- SwiftData, Loki Vault, and semantic-index databases;
- application/update signing keys and release metadata;
- source-authority, provenance, deletion, and synchronization receipts.

## Trust boundaries

- user interface to application coordinator;
- application to Keychain;
- connector transport to normalized admitted records;
- canonical records to derived semantic storage;
- local app to loopback Ollama;
- opt-in external web research;
- source repository to release archive and public repository;
- native macOS read-only REST connector versus the separate, write-capable
  root TypeScript Discord Gateway/moderation runtime.

## Required controls

- Minimum provider scopes and explicit source allowlists.
- Non-enumerating, connector-specific Keychain namespaces.
- No token, payload, content, private path, or hidden-reasoning logging.
- Closed connector kinds, states, reason codes, and provenance schemas.
- Deterministic deduplication, pagination, edit/deletion reconciliation, and
  cancellation.
- Forbidden-write and forbidden-Gateway tests for native Discord, plus SMTP
  prohibition for Support Email.
- Bounds on response size, page count, retries, attachment metadata, input
  files, parsed text, and retained content.
- Fail-closed semantic generation identity and atomic publication.
- Offline classification-only source scans and sanitized publication history.

## Accepted findings and remaining boundaries

- Native Discord and Support Email are locally accepted source-RC additions.
  Their focused, complete, integration, cancellation, persistence,
  disconnect/removal, and disposable-application coverage passed without a
  failure; independent supervisor review found no remaining release blocker.
- Optional live provider smokes were not run and are not required for fixture
  acceptance. No live credentials or provider accounts were used.
- The private development history is not publishable; only a source archive or
  new sanitized public repository is allowed.
- Binary status is `BINARY_DISTRIBUTION_PENDING_SIGNING`; source acceptance does
  not claim Developer ID signing, notarization, packaging, Gatekeeper, or
  clean-install proof.
- The inherited TypeScript bot is write-capable and must remain operationally
  isolated from the native read-only connector.
- P8F signed-smoke bootstrap failures intentionally terminate only an explicitly
  admitted, task-owned smoke process before storage use. An ordinary launch
  without isolation signals selects production storage; production-store open
  failure is caught and returns a temporary in-memory unavailable model without
  resetting the original. Injected invalid isolation intent and failure to
  construct even that fallback remain terminal safety boundaries, not ordinary
  recoverable store-open outcomes.
- `AppLifecycleEventSource` no longer has a continuation precondition; it uses
  `AsyncStream.makeStream` to obtain the stream and continuation as one value.
- Production Discord Keychain, Email security-scoped bookmark capture/reopen,
  and populated V9-to-V10 preservation implementations and test hooks are
  present. Email authorization and migration coverage passed. The Discord and
  Slack Data Protection Keychain hooks were skipped on the unsigned host
  because the required entitlement was unavailable; both skips were classified
  and were not treated as passes.
- The release provenance review confirms the Apache-2.0 selection for
  project-owned source and classifies the icon masters and renditions as
  project artwork contributed to Agent Loki. This resolves the local
  source/artwork classification while retaining a final human publication
  check for later third-party additions and required notices.

## Acceptance evidence

The local pre-seal review recorded:

- complete native: 905 executed, 895 passed, 10 reviewed skips, 0 failed;
- focused 28-class connector/security matrix: 415 executed, 412 passed, 3
  reviewed skips, 0 failed;
- universal unsigned Debug build-for-testing and default Release: passed for
  `arm64` and `x86_64`;
- disposable application smoke: all 20 named selectors passed with no skip or
  failure and successful task-owned cleanup;
- Node 22.23.1: 21 test files and 59 tests passed;
- static XCTest reconciliation: 905 current methods versus 822 baseline, 84
  additions, the single accepted disconnect-test rename, no other removal, and
  no duplicate; and
- release verification plus classification-only secret/history scanning:
  passed without printing matched sensitive values.

The complete run's remaining skips were explicit entitlement, signed-smoke,
live-feed, live-Ollama-model, or authorized disposable V8/Vault-root gates. The
focused run's three skips were the two Data Protection Keychain entitlement
hooks and SecureUpdate live replacement. Remote fixture CI has never run and
remains `READY_TO_RUN`, not a pass.

Exact commit, tag, local-`main`, and source-artifact identities are recorded in
the external verification packet after the local seal. A skipped, blocked, or
unrun check remains named truthfully and cannot be converted into a pass.
