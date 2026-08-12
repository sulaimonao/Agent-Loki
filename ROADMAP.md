# Agent Loki roadmap

The roadmap describes direction, not authorization to mutate or publish.

## v1.0.0-rc.3 Attached Data candidate — verification pending

- [x] Implement bounded read-only SQLite 3 and single-document JSON admission.
- [x] Implement preview, selected collection/field scope, **Link Read-Only**,
      **Import into Vault**, manual refresh, reauthorization, detach, and
      separate local-data removal.
- [x] Preserve complete-generation atomicity, exact provenance, stable record
      identity, privacy-safe status, and local-model consent off by default.
- [x] Document effective limits and unsupported NDJSON, SQLCipher, raw SQL,
      writes, remote databases/JSON, automatic refresh, live multiwriter sync,
      and BLOB-body indexing.
- [x] Add local release-preparation scripts with explicit inputs, exact-tag
      version derivation, deterministic artifact names, safe dry-run, and a
      machine-readable release manifest.
- [ ] Complete final clean-tree RC3 tests, universal builds, release/security
      verification, and accessibility review on the exact candidate.
- [ ] Create and verify the `v1.0.0-rc.3` annotated tag, source archive, SBOM,
      checksums, and clean-history publication repository.
- [ ] If binary distribution is pursued, complete Developer ID signing, DMG,
      notarization, stapling, Gatekeeper, and disposable install evidence.
- [ ] Publish only after the final human rights/privacy review and explicit
      publication authorization.

## v1.0.0-rc.1 source candidate — historical local result

- [x] Preserve the local-first native app and existing Slack behavior.
- [x] Implement and verify the native macOS Discord read-only REST connector.
- [x] Implement and verify local `.eml` and `.mbox` Support Email ingestion.
- [x] Finish public documentation, community files, deterministic CI, privacy
      scans, and source-packaging tooling.
- [ ] Publish through a separately reviewed sanitized source archive or clean
      new public repository. Publication is a later action, not part of this
      local candidate lane.

## Binary distribution

Binary distribution is a separate gate requiring a fresh universal Release
build, Developer ID signing, notarization, stapling, Gatekeeper checks,
packaging, checksums, and disposable install/upgrade/uninstall evidence. No
RC3 binary distribution is currently claimed; its final classification remains
pending fresh artifact evidence.

## Post-release candidates

- Maildir import if it can share the verified local parser safely.
- IMAP read-only synchronization with explicit mailbox allowlisting.
- Additional authenticated read-only connectors.
- Improved accessibility, localization, and contributor tooling.
- A public token-free update host after binary release governance is approved.
- Optional future Attached Data formats only after separate read-only,
  authority, privacy, and bounded-resource review.

## Intentionally out of scope for Connector V1

- Discord user tokens, self-bots, posting, moderation, reactions, or default DM
  ingestion.
- Outbound SMTP or email sending.
- Automatic attachment-body download.
- Cloud storage, mandatory accounts, telemetry, or paid-service requirements.

## Intentionally out of scope for Attached Data RC3

- NDJSON/JSON Lines, SQLCipher/encrypted SQLite, raw or model-authored SQL,
  database writes/migrations, remote databases, and remote JSON/reference
  fetching.
- Automatic refresh, live multiwriter synchronization, unlimited files, and
  BLOB-body indexing.
- Any implicit cloud-model or other remote authority.
