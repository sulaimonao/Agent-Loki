# Changelog

All notable user-facing changes are recorded here. This project follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and uses Semantic
Versioning for source-release tags.

## 1.0.0-rc.3 - 2026-08-11

### Changed

- Replaced maintainer-specific copyright, attribution, fixture, signing,
  update, and publication values with contributor-neutral text or ignored
  operator-local configuration.
- Removed private-project integrations, placeholders, and documentation from
  the distributable source while retaining generic local-model and external
  orchestration boundaries.
- Added unsigned-by-default build settings plus documented opt-in signing,
  Slack, and update configuration for downstream builders.
- Advanced source metadata to `1.0.0-rc.3` and the native application to build
  `3` without rewriting the historical RC1 or RC2 tags.

### Distribution

- The RC3 release lane produces a universal Developer ID-signed, notarized,
  stapled, Gatekeeper-accepted DMG only after the exact copied application
  passes the disposable install smoke gate.
- Apple signatures necessarily identify the Developer ID certificate holder;
  no signing identity, certificate fingerprint, Team ID, credential, private
  update key, or notarization profile is stored in the source repository.

## 1.0.0-rc.2 - 2026-08-10 (unpublished)

### RC2 candidate additions

- Source metadata targets `1.0.0-rc.2`; the native app remains marketing
  version `1.0.0` and advances to build `2`.
- Added Attached Data Sources for bounded, user-selected local SQLite 3 and
  single-document JSON input.
- Added collection/field preview, **Link Read-Only** with manual refresh, and
  **Import into Vault** with continuing file authority removed after success.
- Added complete-generation atomic Vault replacement, deterministic record
  identity and provenance, separate detach and local-data removal, and
  source-scoped local-model consent that defaults off.
- Added keyboard-native Attached Data controls, accessibility labels/hints,
  text-and-symbol status, privacy-safe diagnostics, bounded browse/search, and
  reauthorization guidance.
- Added offline release-preparation scripts for source archives, SBOMs,
  checksums, universal app builds, signing, DMG creation, notarization,
  validation, clean-publication-repository comparison, and a machine-readable
  release manifest/command plan. These scripts do not push, upload, create a
  repository, or create a GitHub Release.

### RC2 candidate boundaries

- SQLite is exact-header-validated, separately opened read-only, and copied to
  a coherent task-owned snapshot. Raw SQL, writes, schema mutation, `ATTACH`,
  unsafe pragmas, SQLCipher, remote databases, and BLOB bodies are unsupported.
- JSON accepts one bounded UTF-8 RFC 8259 object or array and rejects duplicate
  keys, a byte-order mark, trailing data, NDJSON, URLs, and remote references.
- Refresh is manual. Busy/WAL, stale-bookmark, replacement, cancellation, and
  validation failures preserve the last accepted generation.
- Attached Data consent authorizes only selected admitted evidence for an
  existing local model. It grants no remote-model, network, tool, write, or
  publication authority.

RC2 private exact-tree verification passed: the complete native suite executed
1,002 tests (992 passed, 10 reviewed skips, 0 failures), the focused Attached
Data/integration matrix passed 103 of 103, and the disposable application smoke
passed 38 of 38 with cleanup complete. Universal unsigned Debug-for-testing and
Release passed for `arm64` and `x86_64`; Node 22.23.1 built and passed 21 files/
59 tests; and the release verifier accepted 905 RC1-baseline XCTest methods plus
97 additions, for 1,002 current methods.

Those passes are exact-tree evidence. This tracked changelog does not
self-assert its enclosing commit, annotated-tag object, clean public repository,
or external archive/SBOM/checksum identities; the publication packet binds
them, and no artifact is represented as having been created inside the source
tree. Binary status is `BINARY_DISTRIBUTION_PENDING_SIGNING`; signing,
notarization, Gatekeeper validation, and remote publication remain pending at
this candidate record's boundary.

## 1.0.0-rc.1 - 2026-08-08

### Added

- Public Apache-2.0 licensing, community health files, source-build guidance,
  security and privacy documentation, and offline release-verification tools.
- A fixture-only macOS CI contract with immutable action references.
- A fail-closed disposable application smoke runner with an exact named XCTest
  matrix and static About/version/license assertions.
- Native Discord read-only REST ingestion with explicit guild/channel/thread
  authority, resumable bounded reconciliation, metadata-only attachments, and
  privacy-safe status.
- Local Support Email `.eml` and `.mbox` ingestion with bounded MIME parsing,
  HTML sanitization, restart-safe paging, deterministic thread repair, and
  credential-free read-only file authorization.
- Shared connector setup, cancellation, provenance, migration, disconnect, and
  separate local-data removal controls.

### Changed

- Open-source publication is defined as a sanitized source archive or a new
  public repository, not a visibility change to the private development
  history.
- The inherited write-capable TypeScript Discord Gateway/moderation runtime is
  documented separately from the native macOS read-only REST connector.

### Security

- Tracked local session logs and proof receipts are excluded from the candidate
  source tree.
- Release tooling performs classification-only secret and private-path checks
  without printing matched values.

This locally verified source release candidate does not imply a signed or
notarized binary and has not been published.

Current product foundations include the native SwiftUI app, public feeds,
selected-channel Slack, Loki Vault, scheduled local delivery, Agent Loki Chat,
role-assessed local Ollama support, vision input, semantic retrieval, and
explicit source authority. Refer to the repository tags for milestone history;
the current acceptance record is in `docs/OPEN_SOURCE_RELEASE_STATUS.md`.
