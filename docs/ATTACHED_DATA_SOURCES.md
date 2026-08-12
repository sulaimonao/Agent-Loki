# Attached Data Sources

Attached Data Sources lets Loki Brief read a user-selected SQLite database or
JSON document without granting the file, its contents, or a model any broader
authority. The feature is part of the `1.0.0-rc.3` candidate (native version
`1.0.0`, build `3`). Its final release verification is pending.

## Add and preview a source

Open **Sources → Attached Data Sources → Add Data Source…** and choose one
regular local file. Loki Brief rejects directories, symlinks, aliases, files
that change identity while being read, and files that do not match their
detected format.

The preview shows selectable collections and fields, bounded sample records,
source identity, warnings, and a privacy-safe location description. SQLite is
recognized by its exact `SQLite format 3` header rather than its extension
alone. JSON is recognized only as a single UTF-8 JSON document whose first
non-whitespace byte begins an object or array. A filename is never sufficient
proof of format.

Choose what to admit before connecting:

- SQLite: select readable tables or views and fields.
- JSON: select an object or array at the root or at a JSON Pointer, then select
  fields from the normalized records.
- Choose either **Link Read-Only** or **Import into Vault**.
- Leave **Allow this source in explicitly rebuilt local-model indexes** off
  unless local-model use is wanted.

All file reads are bounded and read-only. Each task pins the selected resource
to opened file descriptors, copies into a task-owned snapshot, and verifies the
descriptor and approved path identities before and after capture. Preview does
not import a partial generation if validation, cancellation, or source-identity
checks fail.

## Link Read-Only and Import into Vault

**Link Read-Only** keeps the minimum read-only security-scoped bookmark needed
to reopen the selected file. RC3 refresh is manual: use **Refresh Now**. A
successful refresh atomically replaces the prior accepted Vault generation.
If the file is busy, replaced, stale, malformed, over budget, or changes during
the operation, the prior accepted generation remains available.

**Import into Vault** reads the selected data once into Loki's local Vault.
After a successful import, Loki removes continuing file authority. Later file
changes are not reflected automatically; select the file again to reimport.

These controls are intentionally separate:

- **Detach** removes continuing file authority but retains already admitted
  Loki data.
- **Remove Local Data** removes the source's Vault records, revisions,
  tombstones, and derived semantic evidence. It does not modify or delete the
  original file and does not itself change file authority.

Cancellation and failure never publish a half-generated replacement. Vault
records for a complete accepted generation are replaced atomically; records
omitted from that new generation become tombstones. The last accepted
generation remains intact after a failed or canceled attempt. The frozen import
plan digest is also written into the committed Vault generation marker. After a
restart, a matching marker finalizes the source record and success receipt
without republishing; an absent or mismatched marker clears the pending plan
and leaves the prior generation degraded, or a first import disconnected.
Interrupted local-data removal likewise checks whether the Vault account still
exists before reporting retained or removed state.

## SQLite boundary

Accepted extensions are `.db`, `.sqlite`, and `.sqlite3`, and the file must
also have the exact SQLite 3 header. The admitted file-size limit is 2 GiB.

Loki Brief opens the approved directory, main database, WAL, SHM, and rollback
journal through retained descriptors. It then opens the exact source read-only,
pins SQLite's published view with a read transaction, and uses SQLite's backup
API to create a self-contained task-owned snapshot. Main-file and sidecar
identities are checked before and after capture, the copied snapshot is
normalized to standalone rollback-journal mode, and no snapshot sidecar may
remain. A nonempty rollback journal or incoherent, inaccessible, or changing
sidecar fails closed. The external database is never attached to the production
Vault.

The snapshot connection uses read-only and full-mutex flags with a 250 ms busy
timeout. Admission requires `SQLITE_DBCONFIG_DEFENSIVE=1`,
`SQLITE_DBCONFIG_DQS_DML=0`, and `SQLITE_DBCONFIG_DQS_DDL=0`, and verifies those
controls with runtime probes. It also sets `trusted_schema=OFF` and
`query_only=ON`. The SQLite authorizer permits only bounded reads and narrow
introspection, and denies writes, schema changes, unsafe pragmas, extension
loading, `ATTACH`, `DETACH`, and `VACUUM`. Neither the user nor a model can
supply arbitrary SQL.

Default materialization limits include:

- 10,000 records per accepted source generation;
- 128 selected columns;
- 16 KiB per text field and 128 KiB per normalized record;
- 32 MiB aggregate normalized materialization;
- 250 records per processing page; and
- 15 seconds of SQLite execution.

Internal, virtual, and shadow objects are classified and are not selectable.
Migration-journal, application-private metadata, and over-budget readable
objects are off by default and require explicit selection; selecting an
over-budget object explicitly permits the displayed deterministic truncation.
Safe non-truncating selections are processed first. BLOB bodies are excluded;
Loki may retain only their byte-count metadata. Stable record identity prefers
declared primary keys, then a composite primary key, then `rowid` when
available, and finally a digest of the selected record.

Encrypted or SQLCipher databases, corrupt or unknown formats, remote
databases, raw SQL, database writes or migrations, and live multiwriter
synchronization are unsupported. WAL-mode or concurrently written databases
are accepted only when a coherent read-only snapshot can be obtained; Loki
does not guess through missing sidecars or a busy writer.

## JSON boundary

The selected file must use the `.json` extension and contain exactly one UTF-8
RFC 8259 JSON document. The effective admitted file-size limit is 32 MiB.
Top-level objects and arrays are supported, as are selected nested objects or
arrays addressed by JSON Pointer.

The parser rejects duplicate object keys, a UTF-8 byte-order mark, invalid or
truncated input, and trailing content. URL-like, `$ref`, file-reference, HTML,
and script-looking values are ordinary inert JSON strings: Loki does not fetch,
resolve, interpret, or execute them. Default limits include:

- nesting depth 64;
- 1,000,000 parsed nodes and 10,000 keys per object;
- 100,000 normalized records;
- 1 MiB per string and 64 KiB per numeric token;
- 128 selected fields; and
- 32 MiB aggregate normalized materialization.

Large JSON numbers retain their exact token spelling rather than being rounded
through a floating-point conversion. Stable identity uses an explicitly
selected ID pointer when supplied, an unambiguous recognized ID-like field
when available, or the JSON Pointer plus record digest.

NDJSON/JSON Lines, streaming multiple-document JSON, remote JSON sources,
network fetching, and `$ref` or schema-reference resolution are unsupported.

## Model and network authority

Attached data is local evidence. Connecting, previewing, importing, refreshing,
searching, indexing, and admitting it to model context are separate decisions.

**Allow this source in explicitly rebuilt local-model indexes** defaults off
and applies only to an explicitly selected, already admitted Attached Data
source under Loki's existing local-model consent boundary. It does not
authorize a cloud model, web research, remote database access, publication, a
tool call, or any external write. Loki does not transmit an attached database
or JSON document to a remote provider merely because the source is connected.

Consent revocation and generation changes use a two-phase semantic-authority
handshake. Loki closes new Chat and semantic retrieval admission, drains active
work, and proves the rebuildable semantic index empty before changing canonical
attached-source authority. Admission resumes only after the canonical change
commits or is proven unchanged; a failed purge or unresolved mutation remains
closed and requires recovery rather than exposing stale derived evidence.

For Chat, choose one exact source in the keyboard- and VoiceOver-accessible
Connected Sources picker. One request captures that source's local-import
account, selected Vault containers, epoch, and generation. The read-only tool
executor permits only source health, bounded Vault search, and item reads under
that immutable authority, then revalidates it after the read before publishing
evidence. Generic Vault Chat tools do not expose Attached Data records.

## Search, provenance, and accessibility

Browse and search operate only over the selected and admitted collections and
fields. Results retain source and collection identity plus table/key or JSON
Pointer provenance. Browser and Chat citations project only allowlisted source,
selection, stable-row/record-pointer, epoch, generation, digest, receipt,
identity-strategy, and truncation fields; raw metadata and file paths stay
private. The UI reports bounded counts, digest, generation epoch, last accepted
time, and stable reason codes without displaying a private absolute path.

The Attached Data UI uses native keyboard controls, descriptive labels and
hints, text plus symbols rather than color alone, and explicit status text for
selection, preview, import, refresh, degraded, stale, failed, and disconnected
states. Report an accessibility defect through the normal support route with
the version/build, macOS version, control label, and redacted reproduction.

## Troubleshooting

### The database is busy or its WAL snapshot is unavailable

Close or pause the writer and retry **Refresh Now**. Keep the database, `-wal`,
and `-shm` sidecars together when its producing application requires them.
Loki fails or degrades truthfully instead of importing an incoherent or
partial view. The prior accepted generation is preserved.

### The file needs reauthorization

A security-scoped bookmark may become stale after the file is moved, replaced,
restored, or its volume changes. Choose **Reimport or Replace…**, select the
intended file again, and review the new preview. Loki rejects a different file
silently substituted at the same path.

### The format is reported as unsupported

Confirm that SQLite files have an exact SQLite 3 header and are not encrypted.
Confirm that JSON is one UTF-8 object or array without a byte-order mark,
duplicate keys, trailing data, or NDJSON records. Reducing the file below the
documented limits may be necessary.

### Refresh did not change the imported data

Only linked sources refresh. An imported snapshot deliberately gives up
continuing file authority after success; add the file again to reimport it.
There is no automatic refresh or live database synchronization in RC3.

## Explicitly unsupported in RC3

- NDJSON or JSON Lines;
- SQLCipher or other encrypted SQLite formats;
- raw or model-authored SQL;
- writes, schema changes, migrations, or attaching an external database to the
  Vault;
- remote databases such as PostgreSQL or MySQL;
- remote JSON, URL or reference fetching, schema-reference resolution, or
  execution of active content (URL-like and script-looking strings inside a
  local JSON document remain inert data);
- automatic refresh, live multiwriter synchronization, or unlimited files;
  and
- BLOB-body indexing.
