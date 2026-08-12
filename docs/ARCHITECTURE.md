# Architecture

## Product boundary

Loki Brief is a sandboxed SwiftUI macOS application. It owns user interaction,
source authorization, local persistence, deterministic briefing, optional model
routing, retrieval, deletion, and privacy-safe status. External providers never
receive application authority merely because they are reachable.

The native macOS Discord connector is a verified bounded read-only
REST adapter. The root TypeScript Discord Gateway/moderation runtime is a
separate, inherited, write-capable program. It does not run inside Loki Brief
and is not an implementation dependency of Connector V1.

## Layers

1. **Presentation** — Today, Chat, Sources, Vault, Models, History, Delivery,
   Settings, and About & Privacy views.
2. **Application coordination** — lifecycle, cancellation, update readiness,
   connector operations, scheduling, and user-visible state transitions.
3. **Source adapters** — feeds, Slack, native Discord, local Support Email,
   Attached SQLite/JSON data, and future adapters behind explicit authority.
4. **Canonical stores** — SwiftData control/history records and the local Loki
   Vault SQLite archive.
5. **Derived retrieval** — a separate rebuildable semantic SQLite index bound
   to its exact model/runtime/chunker/source identity.
6. **Optional providers** — numeric-loopback Ollama and separately disclosed
   external web research.

## Trust boundaries

System policy, tool schemas, user requests, application state, and external
source text are distinct authority layers. Connector records are validated and
normalized before admission. Source text can be cited as evidence; it cannot
register a tool, broaden a scope, reveal a credential, or authorize a write.

Credential presence is not connection proof. A connector is connected only
after its authentication, permission, identity, and lifecycle checks succeed.

## Storage

- SwiftData stores application control state, brief/chat history, schedules,
  connector metadata, and user choices.
- Loki Vault stores bounded normalized canonical source evidence and
  provenance in SQLite.
- The semantic index stores derived chunks and vectors in a distinct SQLite
  database and can be rebuilt from admitted canonical records.
- Connector credentials use distinct non-enumerating Keychain namespaces.
- Runtime logs, exports, checkpoints, databases, and local configurations are
  ignored by Git.

Attached Data adds a file-authority control record and normalized canonical
Vault generation, not a second ungoverned database path. A linked source keeps
the minimum read-only security-scoped bookmark needed for manual refresh. An
imported snapshot drops continuing file authority after successful admission.
Private absolute paths are not part of the source receipt.

SQLite preview/materialization retains verified main/WAL/SHM/journal
descriptors while a separate read-only SQLite connection pins the source's
published view in a read transaction and copies it through SQLite's backup API
into a task-owned snapshot; the external database is never attached to the
production Vault. Descriptor and approved path identities must remain stable
throughout capture. Snapshot connections require SQLite defensive mode,
disable double-quoted strings for both DML and DDL, set `trusted_schema=OFF` and
`query_only=ON`, and install a restrictive authorizer.

JSON is parsed as exactly one bounded UTF-8 RFC 8259 document with an effective
32 MiB input boundary. URL-like, `$ref`, file-reference, HTML, and
script-looking strings remain inert scalar data; the adapter performs no
network fetch, reference resolution, or content execution. Both adapters
validate source identity before and after work and admit only selected
collections and fields.

An attached-source publication freezes all material plan fields and binds its
plan digest to the atomic Vault connector-generation marker. On restart, a
matching marker is authoritative proof that the Vault commit occurred, so the
SwiftData source record and receipt are finalized without republishing. If no
matching marker exists, the frozen plan and pending generation are cleared and
the prior accepted generation is retained in a degraded state; a first import
returns disconnected. Removal recovery checks actual Vault account presence
before classifying the source as retained or removed.

Deletion and disconnect must identify which local stores and credentials are
removed, what canonical content remains, and whether external provider data is
unchanged.

## Connector authority

Connector authorization, source/channel/mailbox allowlisting, synchronization,
semantic-index source selection, search-result filtering, model-context use,
and external writes are separate decisions. No checkbox or prior connection
implicitly grants another authority.

For Attached Data, preview, Link/Import mode, manual refresh, detach, local-data
removal, indexing/search, and local-model context are separate decisions.
Local-model consent defaults off and cannot grant cloud-model, network,
database-write, tool, publication, or external-provider authority.

Attached-source consent and generation mutations use a two-phase semantic
authority transaction. Chat and semantic retrieval admission close first;
active work drains and all rebuildable semantic rows must be deleted before the
canonical mutation. The transaction resolves only when canonical state commits
or is proven unchanged. An unproven purge or canonical outcome latches the
boundary closed instead of serving stale derived evidence.

The Connected Sources chat context persists one exact attached-source ID. Each
request captures its local-import account, admitted-container set, epoch, and
generation, restricts the tool plane to source health and bounded Vault reads,
and revalidates the same authority after each read. Generic Vault tools exclude
local-import records. Browser and agent citations receive only the allowlisted
attached provenance projection, never raw Vault metadata or a source path.

See `CONNECTORS.md` for the shared contract and RC3 candidate status, and
`ATTACHED_DATA_SOURCES.md` for the exact format and resource limits.

## Update boundary

Sparkle is pinned as the native update adapter. Automatic checks and automatic
installation default off. Source release acceptance does not require an update
host or signing identity. Binary distribution requires a distinct verified
Developer ID, notarization, package, and update-publication process.

## Failure model

Operations expose stable states and reason codes. Failures preserve canonical
data and prior valid derived generations. Cancellation drains admitted work and
late callbacks cannot publish a replacement result. Tests must exercise
degraded, rejected, canceled, disconnected, and partial-cleanup paths instead
of converting them to success.

Attached Data publishes only a complete accepted Vault generation. A failed or
canceled preview/import/refresh, a busy or incoherent WAL snapshot, a stale or
replaced file, or a validation/limit failure preserves the prior accepted
generation. **Detach** removes continuing file authority; **Remove Local Data**
is a separate mutation of admitted Vault and semantic evidence. Neither action
modifies the original file.

Explicit signed-smoke admission is a separate process mode. Identity or
isolation failure there intentionally terminates that disposable smoke process
before it can touch a store. Ordinary launch without isolation signals selects
production storage. If that store cannot open, construction preserves it and
returns a temporary in-memory unavailable model. `AppModel.live()` terminates
only for invalid injected isolation intent or failure to construct any model,
including the fallback; those are safety boundaries rather than ordinary
store-open behavior. `AppLifecycleEventSource` uses `AsyncStream.makeStream`
and has no continuation precondition.
