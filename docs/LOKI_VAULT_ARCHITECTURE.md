# Loki Vault Architecture

## Architectural boundary

Loki Vault extends the existing native Loki Brief application with two persistence planes and keeps provider retrieval, archive storage, briefing presentation, credentials, and billing abstractions separate.

```text
Authorized provider transport
  -> bounded provider normalization
  -> resumable import/backfill coordinator
  -> actor-isolated SQLite archive
  -> local search / deterministic evidence selection

Data Protection Keychain
  -> credentials only

SwiftData V4 control store
  -> accounts, controls, policy, cursors, summaries, entitlements
```

No archive component creates an incoming listener, background helper, cloud database, or billing-provider dependency.

## Source map

- `VaultDomain.swift`: bounded archive records, search, retention, storage, export, integrity, and recovery contracts.
- `VaultDatabase.swift`: actor-isolated SQLite lifecycle, schema, transactions, CRUD, FTS/fallback search, retention, deletion, storage, export, integrity, checkpoint, compact, and durable backfill persistence.
- `PersistenceModelsP4.swift`: SwiftData V4 control-plane models and the additive V1-to-V4 migration plan.
- `VaultImportCoordinator.swift`: entitlement abstraction and checkpointed reconciliation of P2/P3 evidence.
- `VaultBackfill.swift`: provider-neutral manual job state machine, budgets, source checkpoints, cancellation, and trace contract.
- `SlackVaultBackfillAdapter.swift`: selected-channel Slack history adapter over the existing P3 API client and credential lifecycle.
- `VaultTrace.swift`: allowlisted, bounded, redacted archive events.
- `VaultController.swift` and `VaultViews.swift`: main-actor product integration and native Vault destination.

## Control plane

SwiftData V4 additively retains all V1-V3 entities and adds:

- provider accounts and containers;
- manual synchronization policy;
- backfill summaries and directional cursors;
- storage snapshots and retention policy;
- entitlement evidence;
- deletion records;
- import checkpoints.

The control plane contains no access token, refresh token, authorization code, client secret, raw API response, message body, prompt, or model context.

## Archive plane

`VaultDatabase` is an actor and owns a single SQLite connection opened with full mutex protection. The production archive location is the app-sandbox Application Support path:

```text
Application Support/LokiBrief/Vault/v1/loki-vault.sqlite3
```

The directory is restricted to mode `0700`; the database and exports are restricted to `0600` where supported. SQLite is configured with foreign keys, WAL, synchronous FULL, secure delete, and a five-second busy timeout.

Multi-record operations use explicit `BEGIN IMMEDIATE`, `COMMIT`, and rollback. SQL values are passed through prepared statements and bound parameters. Search filter composition is allowlisted rather than interpolating user text.

## Migration and recovery

The archive schema uses both `PRAGMA user_version` and a migration ledger. Migrations are idempotent and transactional. Opening a database with a newer unsupported schema, failed integrity check, foreign-key issue, FTS inconsistency, lock, or inaccessible path produces a typed recovery classification.

The original archive is never silently deleted, reset, or replaced after migration or integrity failure. Read-only inspection may be offered only when it can be done safely by a separately controlled recovery surface.

## Import reconciliation

P2 feed evidence and P3 Slack evidence enter through `VaultImportSourceReading`. Each request binds owner, account, container, and provider kind. The coordinator:

1. validates entitlement for new historical acquisition;
2. loads or creates an ownership-bound checkpoint;
3. reads a bounded page;
4. validates every evidence scope and original digest;
5. inserts only if absent;
6. commits cursor and counters after the page boundary;
7. pauses truthfully on cancellation or budget exhaustion.

Original SwiftData evidence remains present throughout P4. A digest mismatch fails closed rather than replacing the existing representation.

## Backfill engine

Each job persists provider, state, budget, generation, retry time, source list, forward cursor, historical cursor, usage, and failure state. The engine runs sequentially and only after an explicit user action.

Generation checks reject late results after pause, cancel, account deletion, or another invalidating transition. Provider pages and checkpoint advancement are committed atomically through `VaultBackfillPersisting`. Forward cursors remain immutable to the historical engine.

Rate limits retain the provider's authoritative retry time. Partial source failure does not corrupt successful accounts or containers. Resume must not advance past uncommitted items.

## Slack adapter

The Slack adapter reuses the existing P3 API client, rotating Keychain credential provider, connection identity, channel selection, and normalization. It accepts only enabled public/private channel selections belonging to the connected workspace and rejects DM identifiers.

The adapter does not fetch replies, files, canvases, DMs, workspace search, or raw response envelopes. Channel/account identifiers are hashed in traces; message text is passed only to the archive boundary.

## Search and briefing integration

FTS5 indexes title, normalized body, and author through external-content triggers. If FTS5 creation is unavailable, tokenized LIKE search uses the same bounded filters and deterministic ordering. Search terms are never logged.

The briefing layer may read attributable source evidence from Vault, but backfilled history remains distinct from current incremental evidence. Search does not modify brief ranking, and Ollama cannot modify archive authority.

## Deletion and lifecycle

Account and container archive deletion are transactional and rely on foreign-key cascades for scoped records, revisions, provenance, cursors, jobs, statistics, and FTS triggers. Account deletion orchestration first invalidates jobs and provider requests so late results cannot repopulate deleted scope.

Delete All closes/checkpoints the database before removing the database, WAL, SHM, export staging, P4 controls, existing SwiftData data, and Slack credentials. Partial cleanup is reported rather than concealed. No deletion action touches the repository or unrelated system credentials.

## Observability

Archive and backfill events carry event name, trace/span/parent IDs, component, status, reason code, duration, and bounded counts. Identifiers are hashed before logging. Allowed statuses are `started`, `success`, `degraded`, `failed`, and `skipped`.

Observability exposes decisions and state transitions without raw content or hidden reasoning.
