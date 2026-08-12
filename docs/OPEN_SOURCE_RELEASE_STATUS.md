# Agent Loki V1 Open-Source Release Status

Current source status: **RC3 private exact-tree verification passed**. This
tracked tree cannot self-assert its own enclosing commit, annotated-tag object,
clean-publication-repository, or external artifact identities; those identities
belong in the external publication packet. No source archive, SBOM, checksum,
DMG, or publication artifact is represented as having been created inside the
source tree. Remote publication remains pending at this candidate record's
boundary.

The provisional binary classification remains
`BINARY_DISTRIBUTION_PENDING_SIGNING`; its final RC3 classification requires
fresh evidence from the exact binary artifact. A source candidate may be
released unsigned, but source readiness never implies binary readiness.

This file is the authoritative current candidate-tree inventory. Historical
milestone documents describe their own gates and do not override it. Private
Git history remains local and is not a publication vehicle.

## RC3 release identity

- Source/package version: `1.0.0-rc.3`.
- Release tag name: `v1.0.0-rc.3`; its enclosing annotated-tag object identity
  is recorded externally, not self-asserted by this file.
- Release title: **Agent Loki V1.0.0 Release Candidate 3**.
- Native bundle: `1.0.0` build `3`.
- The RC suffix belongs to source/tag/release metadata because Apple bundle
  versions remain period-separated integers.
- Commit, tag-object, public-repository, archive, SBOM, checksum, and manifest
  identities are bound externally in the publication packet.

## Implemented in the candidate tree

- Existing public feeds, selected-channel Slack, native read-only Discord REST,
  and local `.eml`/`.mbox` Support Email boundaries are preserved.
- Attached Data Sources accepts a user-selected local SQLite 3 database or one
  UTF-8 RFC 8259 JSON document through a bounded read-only file-authority
  boundary.
- Preview exposes only selectable collections and fields, bounded samples,
  warnings, and privacy-safe identity. SQLite detection requires the exact
  header; JSON detection requires one object or array.
- **Link Read-Only** retains a minimum security-scoped read-only bookmark for
  manual refresh. **Import into Vault** performs a one-time snapshot and drops
  continuing file authority after successful admission.
- **Detach** and **Remove Local Data** remain separate so removing continuing
  file authority cannot silently delete admitted data, and deleting Loki data
  cannot modify the original file.
- Complete Vault generations replace atomically. Failure, cancellation, busy or
  incoherent WAL state, stale authority, file replacement, or validation/limit
  rejection preserves the last accepted generation.
- Frozen import plans are digest-bound to the atomic Vault generation marker.
  Restart recovery finalizes a matching committed marker without republishing;
  without a match it clears pending plan state and retains any prior generation
  in a truthful degraded state. Interrupted removal checks actual Vault account
  presence before classifying data as retained or removed.
- Attached Data local-model context is source-scoped, explicitly opt-in, and
  off by default. It grants no remote-model, network, database, tool, write, or
  publication authority.
- Attached-source consent and generation changes use a two-phase purge
  handshake: Chat/semantic admission closes and rebuildable semantic rows are
  deleted before canonical authority changes. An unresolved purge or canonical
  outcome remains fail-closed.
- The Connected Sources picker persists one exact source per chat. Each request
  is pinned to its local-import account, admitted containers, epoch, and
  generation and is reauthorized after every read; generic Vault tools exclude
  Attached Data records.
- The UI uses native keyboard controls, accessibility labels and hints,
  text-and-symbol state, bounded counts, digests, generation epochs, timestamps,
  and privacy-safe reason codes.

See [Attached Data Sources](ATTACHED_DATA_SOURCES.md) for exact limits and
troubleshooting.

## Attached Data limits and exclusions

SQLite admission is limited to exact-header `.db`, `.sqlite`, or `.sqlite3`
files up to 2 GiB. Loki retains descriptor-verified authority for the main file
and its WAL/SHM/journal sidecars while a read-only SQLite transaction pins the
published view and SQLite's backup API produces a task-owned snapshot. The
separate snapshot connection requires SQLite defensive mode, disables
double-quoted strings for
DML and DDL, sets `trusted_schema=OFF` and `query_only=ON`, and uses a
restrictive authorizer. The external database is never attached to the
production Vault. Default accepted output is bounded to 10,000 records, 128
selected columns, 16 KiB per text field, 128 KiB per record, 32 MiB aggregate
materialization, and 15 seconds of execution. BLOB bodies are excluded.

JSON admission is limited to one `.json` UTF-8 RFC 8259 object or array with an
effective 32 MiB file limit. Default parsing/materialization is bounded to
depth 64, 1,000,000 nodes, 100,000 records, 128 selected fields, 1 MiB strings,
and 32 MiB aggregate output. Duplicate keys, a byte-order mark, trailing data,
and invalid or truncated documents are rejected. URL-like, `$ref`,
file-reference, HTML, and script-looking values remain inert strings and are
never fetched, resolved, or executed.

RC3 intentionally does not support NDJSON/JSON Lines, SQLCipher or other
encrypted SQLite formats, raw or model-authored SQL, database writes or
migrations, `ATTACH` to the Vault, remote databases, remote JSON/URLs/reference
fetching, schema-reference resolution, automatic refresh, live multiwriter
synchronization, unlimited files, or BLOB-body indexing.

## RC3 private exact-tree verification evidence

The private candidate exact-tree gates produced this local evidence:

- complete native suite: 1,005 executed, 995 passed, 10 reviewed skips, and
  0 failures;
- focused authority/restart/semantic gate: 8 executed and 8 passed;
- selected three-class Attached Data integration matrix: 60 executed and 60
  passed;
- disposable application smoke: 41 of 41 named tests passed, with task-owned
  cleanup complete;
- universal unsigned Debug build-for-testing and default Release application:
  both passed for `arm64` and `x86_64`;
- exact-commit Node 22 build/test: pending the committed fixture CI workflow
  because the local Node 26 runtime is unsupported; and
- release verifier: passed with an XCTest inventory of 905 annotated
  RC1 baseline methods plus 100 additions, for 1,005 current methods.

These results used fixture-only or task-owned local state. They did not contact
a live provider, perform a remote Git operation, or exercise publication. This
file records the exact-tree results but deliberately does not self-bind its
enclosing commit, tag object, public repository, or external artifacts; the
external publication packet supplies those identities.

## External identity and remaining distribution gates

Any clean-publication-repository audit, public-tag source archive, SPDX SBOM,
final checksum set, release manifest, or publication packet is generated and
reviewed outside this tracked source tree. Their identities must be recorded in
that external packet rather than embedded here. DMG signing, notarization,
stapling, Gatekeeper validation, and remote publication remain pending. Remote
compatibility CI also remains unrun and must be recorded truthfully rather than
inferred from the local exact-tree passes.

## Release automation present

The repository contains offline-first preparation scripts for:

- universal app build: `scripts/build-release-app.sh`;
- Developer ID signing: `scripts/sign-release-app.sh`;
- DMG construction: `scripts/create-dmg.sh`;
- notarization and stapling: `scripts/notarize-dmg.sh`;
- signed/stapled/Gatekeeper/mounted-app validation:
  `scripts/verify-dmg.sh`;
- source packaging: `scripts/package-source-release.sh`;
- SPDX 2.3 SBOM generation: `scripts/generate-sbom.sh`;
- SHA-256 checksums: `scripts/generate-checksums.sh`;
- clean publication-repository comparison:
  `scripts/verify-publication-repo.sh`; and
- local GitHub Release manifest and command-plan preparation:
  `scripts/prepare-github-release.sh`.

The scripts require explicit inputs, derive the version from the matching
annotated tag, reject a dirty or wrong-tag candidate, use deterministic names,
and support non-mutating dry-run planning. They do not push, upload, create or
change a repository, create a GitHub Release, install dependencies, or supply
credentials. Their presence is not proof that build, signing, notarization,
validation, or publication ran.

## Binary gate pending

Public DMG distribution requires one exact universal Release application that
passes Hardened Runtime/entitlement review, Developer ID signing, DMG signing,
Apple notarization, stapling, `spctl` Gatekeeper assessment, mounted-app
signature/team/architecture checks, checksums, and disposable install/upgrade/
uninstall validation. Signing identities, notarization Keychain profiles,
private update keys, and notarization records remain outside source control.

Until those checks pass on immutable artifacts, no RC3 public binary is ready.

## Historical RC1 record

`v1.0.0-rc.1` is a historical locally verified source candidate, documented in
[the RC1 release notes](RELEASE_NOTES_1.0.0_RC1.md). Its accepted local
evidence included 905 native tests (895 passed, 10 reviewed skips), a focused
415-test connector/security
matrix (412 passed, 3 reviewed skips), 20 disposable-smoke selectors, universal
unsigned builds, and 59 Node tests. RC1 was not published and did not establish
a signed/notarized binary. Those results remain valid history but are not RC3
acceptance evidence.

## Publication-history boundary

Private ancestry contains machine-local proof paths, tracked historical session
logs, and deleted message-shaped fixture content that is not accepted as a
public fixture. No visibility change, private ref/tag publication, history
rewrite, push, or release creation is authorized by these documents.

The only permitted publication vehicle is a verified sanitized source archive
or a separately initialized clean-history public repository containing exactly
that reviewed tree. Before its first push, compare it to the approved archive,
scan every reachable object for excluded artifact classes, and inspect all
configured remotes. The final human rights, privacy, notices, and artifact
review remains pending.
