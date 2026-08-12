# Agent Loki V1.0.0 Release Candidate 2

- Source version/tag target: `1.0.0-rc.2` / `v1.0.0-rc.2`.
- Native bundle version: `1.0.0` build `2`.

## Candidate status

RC2 adds Attached Data Sources for bounded read-only SQLite and JSON use in
Loki Brief. The implementation and documentation are present in the candidate
tree. Private exact-tree tests, builds, smoke, Node verification, and the
release verifier passed. This tracked note cannot self-assert its enclosing
commit, annotated-tag object, clean-publication-repository, or external artifact
identities; the external publication packet binds them. It does not claim that
an archive, SBOM, checksum, DMG, or publication artifact was created inside the
source tree. Signing, notarization, Gatekeeper validation, and remote
publication remain pending at this candidate record's boundary.

RC1 remains the historical locally verified source candidate documented in
[the RC1 release notes](RELEASE_NOTES_1.0.0_RC1.md). RC2 requires its own
exact-candidate evidence and does not inherit RC1 test or artifact results.

## Private exact-tree verification

- Complete private native suite: 1,002 executed, 992 passed, 10 reviewed skips,
  0 failures.
- Focused Attached Data/integration matrix: 103 of 103 passed.
- Disposable application smoke: 38 of 38 named tests passed; task-owned cleanup
  completed.
- Universal unsigned Debug build-for-testing and default Release application:
  both passed for `arm64` and `x86_64`.
- Node 22.23.1 build: passed; 21 test files and 59 tests passed.
- Release-verifier inventory: 905 annotated RC1 baseline XCTest methods plus 97
  additions, for 1,002 current methods; the verifier passed.

These local results used no live-provider authority and performed no remote Git
or publication action. Their enclosing commit, tag-object, public-repository,
and external artifact identities are recorded in the publication packet rather
than self-asserted here.

## Added

- One Attached Data Sources surface under Sources for user-selected local
  SQLite and JSON files.
- Format-aware preview of selectable collections, fields, bounded samples,
  warnings, and privacy-safe source identity.
- **Link Read-Only**, with a minimum read-only security-scoped bookmark and
  manual refresh, and **Import into Vault**, a one-time local snapshot that
  drops continuing file authority after success.
- Atomic Vault generations: a complete accepted refresh replaces the prior
  generation, while failure or cancellation preserves the last accepted data.
- Cross-store restart recovery binds each frozen import plan digest to the
  atomic Vault generation marker. A matching committed marker finalizes the
  source receipt without republishing; an absent marker clears pending state
  and preserves the prior generation truthfully.
- Separate **Detach** and **Remove Local Data** operations so file authority and
  retained local evidence are never conflated.
- Exact table/key or JSON Pointer provenance, deterministic record identity,
  bounded browse/search, and BLOB metadata without BLOB bodies.
- An opt-in **Allow this source in explicitly rebuilt local-model indexes**
  control, off by default. It grants no remote-model, web, database,
  publication, tool, or write authority.
- A two-phase semantic purge handshake closes Chat/retrieval admission and
  deletes rebuildable semantic rows before attached-source consent or
  generation authority changes; unresolved state remains fail-closed.
- A Connected Sources chat selects one exact source. Requests pin its account,
  admitted containers, epoch, and generation; generic Vault tools exclude
  Attached Data, and authority is revalidated after reads before publication.
- Keyboard-native controls, accessibility labels and hints, non-color-only
  state communication, stable reason codes, counts, digests, and generation
  status.
- Offline release-preparation scripts for source packaging, SBOM and checksum
  generation, universal app build, signing, DMG creation, notarization,
  validation, clean-publication-repository verification, and a machine-readable
  local GitHub Release manifest/command plan.

## SQLite boundary

- Local `.db`, `.sqlite`, and `.sqlite3` files must also carry the exact SQLite
  3 header; admitted files are capped at 2 GiB.
- Loki retains descriptor-verified authority for the main database, WAL, SHM,
  and rollback journal, pins SQLite's published view in a read transaction,
  and copies that view through SQLite's backup API into a coherent task-owned
  snapshot. It never attaches the external database to the production Vault.
- Snapshot connections require SQLite defensive mode, disable double-quoted
  strings for DML and DDL, set `trusted_schema=OFF` and `query_only=ON`, and
  enforce a restrictive authorizer.
- Selection is limited to readable tables/views and fields. Raw SQL, writes,
  schema mutation, unsafe pragmas, extension loading, and BLOB bodies are
  denied.
- Default output limits are 10,000 records, 128 selected columns, 16 KiB per
  text field, 128 KiB per record, 32 MiB aggregate materialization, and 15
  seconds of SQLite execution.
- Busy, WAL/sidecar, encrypted, corrupt, replaced, or concurrently changing
  inputs fail or degrade without publishing partial data.

## JSON boundary

- One local `.json` file containing a single UTF-8 RFC 8259 object or array;
  the effective admitted file limit is 32 MiB.
- Root or selected nested object/array materialization through JSON Pointer,
  with duplicate-key rejection and exact large-number token preservation.
- Default limits include depth 64, 1,000,000 nodes, 100,000 records, 128
  selected fields, and 32 MiB aggregate materialization.
- NDJSON/JSON Lines, a UTF-8 byte-order mark, multiple documents, trailing data,
  remote JSON, network fetching, and schema/reference resolution are rejected
  or unsupported. URL-like, `$ref`, file-reference, HTML, and script-looking
  values inside the admitted document remain inert strings and are never
  fetched, resolved, or executed.

## Not included

RC2 does not add SQLCipher support, arbitrary SQL, database writes or
migrations, remote databases, remote JSON, automatic refresh, live multiwriter
sync, BLOB-body indexing, cloud-model consent, or any new remote authority.

## Release and publication boundary

Release scripts require explicit inputs and an exact clean annotated tag at
`HEAD`; the version is derived from that tag and artifact names are
deterministic. Their dry-run paths do not build, sign, notarize, push, upload,
create a repository, or create a GitHub Release. The preparation script emits
local machine-readable evidence and a command plan only.

The private development repository and its ancestry are not a publication
vehicle. Any public repository must be a separately audited clean-history
export matching the approved source archive. This note does not assert the
external archive, repository, or publication-packet identities. Binary
classification remains `BINARY_DISTRIBUTION_PENDING_SIGNING`; signing,
notarization, and remote publication remain pending subject to the checklist in
[the publication checklist](PUBLICATION_CHECKLIST.md).
