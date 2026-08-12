# Agent Loki

Agent Loki is a local-first macOS knowledge and assistant application. The
native app, **Loki Brief**, builds attributable daily briefs, keeps an optional
local archive, and can answer questions over sources the user explicitly
authorizes. Local Ollama models are optional; deterministic features continue
to work without a model or cloud account.

## Release status

The repository contains the in-progress **v1.0.0-rc.3** source candidate
(native version `1.0.0`, build `3`). Private pre-seal verification passed: the
native suite recorded 995 passes plus 10 reviewed skips from 1,005 executed,
the focused authority/restart/semantic gate passed 8 of 8, the selected
three-class Attached Data integration matrix passed 60 of 60, the disposable smoke passed
41 of 41 with cleanup complete, and both universal unsigned builds passed. The
verifier accepted 905 RC1-baseline XCTest methods plus 100 additions, for 1,005
current methods. The local host's Node 26 is outside the
supported range, so exact-commit Node 22 build/test evidence must come from the
committed fixture CI workflow rather than an unsupported local substitution.

Those results are not yet bound to a final commit, annotated tag, clean public
repository, or immutable artifact. RC3 source archive, SBOM, checksums, DMG,
signing, notarization, Gatekeeper checks, and publication remain pending. Binary
status is `BINARY_DISTRIBUTION_PENDING_SIGNING`.

The historical **v1.0.0-rc.1** source candidate was locally verified but was
not published; its record remains in
[the RC1 release notes](docs/RELEASE_NOTES_1.0.0_RC1.md). RC3 must obtain its
own exact-candidate evidence and does not inherit those results.

- Native Slack support is preserved and remains explicit, selected-channel,
  and read-only.
- Native macOS Discord read-only REST ingestion is implemented and accepted by
  synthetic fixture, persistence, cancellation, reconciliation, and
  forbidden-write coverage.
- Local Support Email import for `.eml` and `.mbox` is implemented and accepted
  by synthetic parser, paging, restart, reconciliation, and Vault coverage.
  Maildir is not included.
- RC3 adds user-selected local SQLite and JSON Attached Data Sources with
  bounded preview, descriptor-pinned task snapshots, **Link Read-Only** or
  **Import into Vault**, manual refresh, recoverable atomic Vault generations,
  and separate detach and local-data removal.
- IMAP and all outbound email are deferred.
- Live Slack, Discord, and email-account smokes were not run. They are optional
  credentialed gates and are not substitutes for the accepted fixture suite.
- A source release can be unsigned. Binary distribution remains a separate
  signing, notarization, packaging, and clean-install gate.

See [the release status](docs/OPEN_SOURCE_RELEASE_STATUS.md) for the current
candidate record and [Attached Data Sources](docs/ATTACHED_DATA_SOURCES.md) for
the exact SQLite/JSON boundary.

## Repository surfaces

### Native macOS application

`macos/LokiBrief` contains the SwiftUI application and its tests. Its principal
boundaries are:

- public HTTPS feeds;
- selected-channel Slack ingestion;
- local Loki Vault storage and provenance;
- optional loopback-only Ollama generation, vision, and embeddings;
- opt-in external Ollama Web Research with a separate credential and visible
  disclosure;
- read-only connector records admitted through a closed source-authority
  boundary;
- local SQLite and JSON files selected by the user, opened read-only, and
  admitted only through selected collections and fields; and
- explicit local-model consent for attached data, off by default and never a
  grant of remote-model, network, database-write, or publication authority.

Read [Architecture](docs/ARCHITECTURE.md) and
[Connectors](docs/CONNECTORS.md) before changing these boundaries.

### Legacy TypeScript Discord Gateway/moderation runtime

The root Node.js project is an inherited Discord copilot/moderator runtime. It
uses the Discord Gateway and is **not** the native macOS read-only REST
connector. It uses a bot credential, registers Discord interactions, can reply
or post, and contains separately approved moderation actions. Although
moderation enforcement defaults off, the runtime is still write-capable. Never
reuse its transport or credential as proof that Connector V1 is read-only.

Operate the legacy bot only in an explicitly isolated test guild with a
nonempty guild allowlist. Do not run global command registration casually.

## Privacy and safety

- Canonical application data stays on the Mac unless the user explicitly
  invokes a disclosed provider operation.
- Slack, Discord, update, and optional web-research credentials belong in the
  macOS Keychain or ignored local configuration, never in Git.
- Tests use synthetic fixtures and must not contact real accounts.
- Telemetry, analytics, crash upload, and remote logging are off because they
  are not part of the product.
- Connector content is untrusted evidence, never application policy or tool
  authority.
- Attaching a file does not silently authorize model context. Attached Data
  model use is local-only, source-scoped, and separately opt-in; no remote
  provider receives authority from that choice.
- Attached-source consent and generation changes close Chat/semantic admission
  and purge rebuildable semantic rows before the canonical authority mutation;
  an unresolved purge or mutation remains fail-closed.
- A Connected Sources chat must select one exact consented source. Its request
  is pinned to that source's account, admitted containers, epoch, and
  generation; generic Vault tools exclude Attached Data, and stale authority
  is rechecked after every read before evidence can be published.

Read [Privacy](PRIVACY.md) and [Security](SECURITY.md) for the complete public
boundary.

## Build and test

Requirements:

- native deployment target: macOS 14.0 or later;
- locally exercised RC3 pre-seal toolchain: macOS 26.6, Xcode 26.6 (`17F113`),
  and Swift 6.3.3;
- CI compatibility target: the `macos-15` runner with Xcode 16.4 selected
  explicitly; this remains `READY_TO_RUN` until GitHub executes the workflow;
- Node.js `>=22 <23` for the legacy runtime. Fixture CI selects Node 22. The
  local host's Node 26 is outside the supported engine range and cannot build
  the pinned `better-sqlite3` graph, so it is not release evidence;
- the exact dependencies recorded in `Package.resolved` and
  `package-lock.json`.

Start with:

- [Building](docs/BUILDING.md)
- [Testing](docs/TESTING.md)
- [Release verification](docs/RELEASING.md)

Dependency installation may contact the configured package sources. The
release scripts themselves are offline by default and never install packages.

For development checks, keep all live-provider opt-ins unset and run:

```sh
scripts/verify-release.sh --allow-dirty   # omit --allow-dirty for final proof
npm ci
npm run build
npm test
```

Then run the native fixture command in [Testing](docs/TESTING.md) with a fresh
derived-data directory outside the repository. After the suite passes, run the
bounded named smoke matrix:

```sh
scripts/run-disposable-app-smoke.sh
```

The smoke runner creates and removes task-owned DerivedData and store roots,
uses synthetic connector fixtures, and never replaces the installed app. These
commands do not authorize a live Slack, Discord, Email, Ollama, or
update-provider request. The private pre-seal suite and 41-test smoke passed,
but their evidence is not yet final-tag-bound; see
[Releasing](docs/RELEASING.md).

## Known limitations

- Exact commit/tag binding, clean-publication-repository verification, and
  remote compatibility CI for RC3 are pending.
- Native Discord and local Support Email are accepted source-candidate features;
  their live-provider smokes remain deliberately unrun.
- Support Email V1 imports local `.eml` and `.mbox` files. Maildir, IMAP,
  provider OAuth, SMTP, and outbound mail are not included.
- Scheduling requires the app to remain running. Ollama is optional and must be
  installed separately.
- Attached Data supports one local RFC 8259 JSON document, with an exact 32 MiB
  input boundary, or a local SQLite 3 database within documented limits.
  URL-like, `$ref`, and script-looking JSON strings remain inert data: Loki does
  not fetch, resolve, or execute them. NDJSON, SQLCipher, arbitrary SQL, writes,
  remote sources, automatic refresh, live multiwriter sync, and BLOB-body
  indexing are unsupported.
- SQLite reads retain descriptor-verified authority for the database and its
  sidecars, pin SQLite's published view in a read transaction, and use SQLite's
  backup API to create a task-owned snapshot. A changing source, missing or
  incoherent sidecar, busy writer, or nonempty rollback journal may prevent a
  coherent snapshot; linked sources then preserve their last accepted
  generation and require a manual retry. Moved or replaced files may require
  reauthorization.
- Vault content and user-created exports are not application-level encrypted.
- No signed/notarized RC3 binary, public update host, or publication is claimed.

## Contributing and support

Contributions are welcome under [Apache License 2.0](LICENSE). Read
[CONTRIBUTING.md](CONTRIBUTING.md) and [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
Use [SUPPORT.md](SUPPORT.md) for help and [SECURITY.md](SECURITY.md) for private
vulnerability reporting.

## Publication boundary

The private development repository contains historical local proof artifacts
and deleted message-shaped fixtures in its ancestry. Do not make that
repository public. The authorized publication vehicle is a reviewed source
archive or a clean-history export/new public repository created from the
accepted candidate tree. See
[Publication Checklist](docs/PUBLICATION_CHECKLIST.md).
