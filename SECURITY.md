# Security policy

## Supported versions

Security fixes target the current source release candidate and the latest
published source release. Historical milestone tags are retained for
provenance and are not independently supported release lines.

## Report a vulnerability privately

Use **Security → Report a vulnerability** in the public GitHub repository when
private vulnerability reporting is available. Do not open a public issue with
exploit details, credentials, private data, or affected-user information.

If private reporting is unavailable, open a minimal public issue asking the
maintainer to enable a private channel. Include no vulnerability detail beyond
the request for private contact. A public security email is intentionally not
guessed or hardcoded.

## What to include

- affected commit, tag, version, and component;
- impact and prerequisite conditions;
- minimal reproduction using synthetic data;
- whether the issue crosses a connector, Keychain, sandbox, local-store,
  update, or logging boundary; and
- any safe mitigation already tested.

## Response principles

Maintainers will acknowledge, reproduce, classify, repair, and coordinate
disclosure according to severity and user impact. A fix is not considered
released until it is verified on an exact source commit and, for binary-only
issues, on the exact signed artifact.

## Security boundaries

- Connector credentials belong in Keychain and must never be enumerated or
  logged.
- Provider content is untrusted evidence and cannot authorize tools or writes.
- The verified native macOS Discord Connector V1 uses bounded read-only REST
  requests with an official bot identity; Gateway use, user tokens, and
  self-bots are prohibited.
- The separate root TypeScript Discord Gateway/moderation runtime is
  write-capable and is not Connector V1.
- Support Email V1 is local file ingestion; outbound SMTP is prohibited.
- Attached SQLite/JSON files are opened through read-only security-scoped
  authority. Symlinks, aliases, directories, nonregular files, same-path
  replacement, and identity changes during a read are rejected. Task reads are
  pinned to opened file descriptors and verified against path identity before
  and after snapshot capture.
- SQLite admission requires the exact SQLite 3 header and retains verified
  descriptors for the database, WAL, SHM, and rollback journal while SQLite
  pins its published view in a read transaction and copies it through the
  backup API into a task-owned snapshot. Main-file and sidecar identities are
  verified before and after capture. Snapshot connections require SQLite
  defensive mode, disable double-quoted
  strings for DML and DDL, set `trusted_schema=OFF` and `query_only=ON`, and use
  a restrictive authorizer. Writes, schema mutation, `ATTACH`, unsafe pragmas,
  extension loading, and arbitrary user- or model-authored SQL are denied. The
  external database is never attached to the production Vault.
- JSON admission requires one UTF-8 RFC 8259 object or array within the exact
  32 MiB input boundary and rejects duplicate keys, trailing content, NDJSON,
  and malformed input. URL-like, `$ref`, file-reference, HTML, and
  script-looking values are inert strings; Loki neither rejects them merely for
  their spelling nor fetches, resolves, or executes them. SQLCipher/encrypted
  databases and remote sources are not supported.
- Attached Data local-model consent defaults off, is limited to selected
  admitted evidence, and grants no cloud-model, network, tool, publication, or
  write authority.
- Refresh/import publishes one complete Vault generation atomically. Busy,
  stale, replaced, canceled, malformed, or changing sources preserve the prior
  accepted generation rather than admitting partial data.
- A frozen import plan is bound to the Vault generation marker by its digest.
  Restart recovery finalizes a matching committed marker without republishing;
  an absent or mismatched marker clears the pending plan and retains any prior
  accepted generation in a truthful degraded or disconnected state.
- Attached-source consent, generation, and evidence-removal boundaries close
  Chat/semantic admission and await deletion of rebuildable semantic rows
  before canonical authority changes. Admission reopens only after the
  canonical mutation is committed or proven unchanged; unresolved state stays
  fail-closed.
- Each Connected Sources chat request captures one selected attached source's
  account, admitted-container set, epoch, and generation. Generic Vault tools
  exclude local-import records, and exact-source authority is checked before
  and after each read so a concurrent exclusion cannot publish stale evidence.
- Ordinary tests use fixtures and must not access live accounts.
- Source releases may be unsigned. Binary trust requires a separate signing
  and notarization gate.

See `docs/ATTACHED_DATA_SOURCES.md` for limits and troubleshooting and
`docs/SECURITY_REVIEW.md` for the candidate review checklist. Final RC3
security tests and exact-tag release verification remain pending.
