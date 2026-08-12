# Loki Vault Database Schema

## Database identity

- Engine: system SQLite; no third-party database package.
- Current archive schema version: `3`.
- Default file: `Application Support/LokiBrief/Vault/v1/loki-vault.sqlite3` inside the app sandbox.
- Directory permissions: `0700` where supported.
- Database/export permissions: `0600` where supported.

Required connection configuration:

```sql
PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;
PRAGMA synchronous = FULL;
PRAGMA secure_delete = ON;
PRAGMA busy_timeout = 5000;
```

Migrations execute in an explicit immediate transaction. `PRAGMA user_version` and `vault_schema_migrations` must agree with the supported application version.

## Tables

### `vault_schema_migrations`

Records applied schema versions and timestamps. It makes repeated migration attempts idempotent and inspectable.

### `vault_features`

Records runtime feature classification such as `fts5=available` or `fts5=fallback`.

### `vault_accounts`

Stores stable local account ID, provider kind, stable provider-owned account ID, bounded display name, and creation/update times. `(provider, provider_account_id)` is unique.

Credentials never belong in this table.

### `vault_containers`

Stores stable container ID, owning account, provider-owned container ID, container kind, display name, and timestamps. `(account_id, provider_container_id)` is unique. Account deletion cascades to its containers.

### `vault_records`

Stores the current normalized source representation:

- stable archive, account, container, and provider record IDs;
- item kind, bounded title/body, author, and optional source URL;
- source occurrence, retrieval/capture, modification, and insertion times;
- bounded metadata JSON;
- revision and SHA-256 content checksum;
- direct-mention and read state;
- source/generated origin;
- provider metadata version;
- optional thread root and bounded reply count.

`(account_id, container_id, provider_record_id)` is unique. The referenced container must belong to the referenced account.

The table never stores credentials, authorization material, full raw API envelopes, attachment bodies, image files, scripts, unbounded HTML, prompts, or model context.

### `vault_revisions`

Stores prior content only when a content hash changes. `(record_id, revision)` is the primary key. Unchanged updates do not create revisions. Each record retains at most ten revisions in P4.

### `vault_tombstones`

Preserves stable identity, account/container scope, provider record ID, reason, observation time, and whether prior private content was purged. Tombstoning removes the current record and its FTS content; it does not retain deleted private content indefinitely.

### `vault_participants` and `vault_item_participants`

Provide provider-neutral participant identity and record-role relationships. Participants are scoped to an account and use provider-owned identifiers.

### `vault_provenance`

Stores provider, provider account/container/item identifiers, retrieval time, optional source URL, and source/generated origin for each current record.

### `vault_sync_cursors`

Stores independent `forward` and `historical` cursor rows per account/container, including provider cursor, time boundary, last success, last rate limit, last failure, and exhaustion state. One direction never overwrites the other.

### `vault_sync_runs`

Stores bounded run status, direction, reason code, timestamps, request count, and item count for account/container synchronization.

### `vault_backfill_jobs`

Stores the versioned job and checkpoint JSON as bounded blobs plus provider, state, and update time. Job and archive-page persistence share an explicit transaction so a cursor cannot acknowledge uncommitted items.

No credential or raw response is serialized into job/checkpoint blobs.

Jobs are account-scoped by their provider plus checkpoint source identities. Account deletion decodes that bounded scope and deletes matching job/checkpoint rows transactionally before deleting the account; unrelated jobs remain intact.

### `vault_storage_statistics`

Stores timestamped global or account-scoped item, revision, and estimated-byte measurements. Exact file/WAL/SHM sizes are measured from local files at report time.

### `vault_records_fts`

When FTS5 is available, an external-content index covers title, body, and author. Insert/update/delete triggers keep it synchronized with `vault_records`. Integrity checks can rebuild the index without changing source records.

When unavailable, the database records the fallback feature state and uses bounded prepared LIKE queries.

## Indexes and ordering

The schema indexes account/date, container/date, author, and tombstone scope. Versioned insert/update triggers reject any record, tombstone, cursor, or container-bound sync run whose account does not own the referenced container, and container ownership is immutable. These triggers are idempotently installed when an existing supported archive opens, including an archive already at the current `user_version`. Search and export add stable archive IDs as deterministic tie breakers. Export orders provider/account/container/record/revision/tombstone/provenance rows explicitly.

## Transactions and binding

All user/provider values use prepared statements and bound parameters. Multi-row upsert, tombstone, retention, deletion, and backfill commits use explicit transactions with rollback on failure.

Search SQL is assembled only from fixed allowlisted clauses. User search text is tokenized, bounded to 512 characters and 16 tokens, then bound; raw FTS syntax is not accepted.

## Integrity and recovery

The integrity gate checks:

- `PRAGMA integrity_check(1)`;
- `PRAGMA foreign_key_check`;
- required table presence;
- FTS consistency when FTS5 is enabled;
- supported schema version.

Failures classify as healthy, migration required, locked/retryable, unsupported-newer-schema, corruption-preserve-original, foreign-key repair required, FTS rebuild required, inaccessible-preserve-original, closed, or unknown-preserve-original.

The application never silently replaces or resets a failed archive.

## Deletion behavior

Account/container deletion is scoped and transactional. Foreign-key cascades remove dependent current records, revisions, participants, provenance, cursors, runs, statistics, and FTS entries. Account-scoped job/checkpoint blobs are identified and deleted explicitly inside the same transaction. Unrelated accounts, jobs, providers, and application settings remain intact. Credentials are removed only by an explicit disconnect action.

Retention tombstones expired records, removes obsolete tombstones within the selected scope, prunes revisions through record deletion, and updates storage reporting. It never crosses the selected account/container boundary.

## Export representation

`.lokivault` is newline-delimited canonical JSON. Every line has a sequence number, type, payload, and payload checksum. The first line is a manifest containing format, schema version, export time, account/date scope, counts, line count, and aggregate payload checksum.

Exports exclude Keychain values, credentials, secrets, raw responses, prompts, hidden reasoning, and signing material. P4 exports are local and unencrypted.
