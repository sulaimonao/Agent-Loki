# Connector contract

## Candidate status

| Source | Native state | Release boundary |
| --- | --- | --- |
| Public RSS/Atom/JSON Feed | Implemented | Explicit public HTTPS URL |
| Slack | Implemented and preserved | Read-only selected channels, PKCE, Keychain |
| Discord | Implemented and locally verified | Native macOS bounded REST reads with an official bot identity and explicit guild/channel/thread selection |
| Support Email | Implemented and locally verified | User-selected local `.eml`/`.mbox`; no credential required |
| Attached Data | Implemented; final RC3 verification pending | User-selected local SQLite 3 or single-document JSON; selected collections/fields only |
| Maildir | Deferred | Not included in the candidate |
| IMAP | Deferred | No live mailbox access in V1 |

Native Discord and Support Email results above are the historical RC1 local
acceptance record. Optional live Slack/Discord account smokes were not run and
are not source-RC acceptance requirements. Attached Data is new in RC3; its
final exact-candidate fixture, regression, disposable application smoke, build,
and release-verification results are pending.

## Shared record

A connector should provide stable connector kind, account/workspace identity,
display name, explicit allowlist, connection state, cursor, last attempt and
success time, imported/skipped/attachment counts, privacy classification,
structured failure and retry state, deterministic record identity, provenance,
edit/deletion identity, disconnect behavior, local-data policy, and a bounded
receipt.

User-visible lifecycle states are:

- unavailable;
- disconnected;
- connecting;
- connected;
- syncing;
- degraded;
- failed; and
- disabled.

A token or file path alone never establishes `connected` or `syncing`.

Attached Data additionally exposes selecting, previewing, ready, importing,
refreshing, stale, and disconnected states. State is communicated with text
and symbols, not color alone, and controls have native keyboard behavior plus
accessibility labels and hints.

## Credentials

Each authenticated provider uses an isolated, non-enumerating Keychain
namespace. Credentials never enter SwiftData, Vault, semantic indexes, exports,
logs, fixtures, or Git. Disconnect must state whether it revokes the remote
credential, deletes the local credential, deletes imported local data, or
preserves data for a separate explicit choice.

## Native macOS Discord Connector V1

- Use an official Discord application/bot identity; never a user token or
  self-bot.
- Request only the minimum scopes, intents, and guild/channel permissions.
- Default DMs off and permit only explicitly selected guilds, channels, and
  threads.
- Use bounded read-only REST history polling. Do not connect to the Gateway.
- Segment large histories into resumable syncs. Persist the returned
  continuation/reconciliation state after admitted Vault writes so a 5,000
  message or 32 MiB output cap does not restart the scan.
- Bound the existing materialized corpus at 100,000 connector envelopes and
  128 MiB of aggregate materialized envelope bytes before accepting more work.
- Preserve message, author, guild, channel, thread, reply, edit, deletion, and
  attachment-metadata identity.
- Reconcile pagination, duplicate and out-of-order pages, rate limits, edits,
  and tombstones deterministically.
- Rotate selected sources fairly, including when one selection has a tombstone
  backlog, so later selections continue to make progress without discarding
  the earlier continuation.
- Treat forum and media parents as nonselectable thread containers. Their child
  threads may be selected and synchronized within the same read-only bounds.
- Never invoke a send, edit, delete, reaction, moderation, or webhook endpoint.
- Download no attachment body without a distinct user action.

The native connector must not import or call the root TypeScript
Gateway/moderation runtime. That legacy runtime is write-capable and has a
different transport, credential, database, permission model, and user intent.
It is not Connector V1.

## Support Email V1

- Parse user-selected local `.eml` and `.mbox` files without network access.
- Preserve message/thread headers, addressing, dates, subject, supported text,
  and attachment metadata when present.
- Prefer plain text; sanitize HTML to inert text; never execute remote content.
- Use a deterministic source identity when `Message-ID` is missing.
- Make repeated imports idempotent across pages and restarts, including
  conflicting or duplicate `Message-ID` values.
- Checkpoint compact locator/ancestry state so thread relations converge across
  pages and restarts. If a parent arrives after its child, bounded repair-only
  pages deterministically re-emit the child and update its Vault thread root;
  retry and restart preserve that repair atomically.
- Ignore attachment bodies by default and report malformed or oversized input
  truthfully.
- Never send email or implement SMTP in V1.

IMAP is deferred and does not block the local source release.

## Attached Data Sources RC3

- Accept one user-selected regular local file. Reject symlinks, aliases,
  directories, nonregular files, same-path replacement, and source identity
  changes during the operation.
- Accept `.db`, `.sqlite`, or `.sqlite3` only with the exact SQLite 3 header,
  up to 2 GiB. Open a separate read-only connection with a 250 ms busy timeout
  and materialize from a coherent task-owned backup snapshot.
- Accept `.json` only as one UTF-8 RFC 8259 object or array, up to an effective
  32 MiB file limit. Reject duplicate keys, a byte-order mark, trailing data,
  NDJSON, URLs, references, and active content.
- Preview and admit only selected tables/views or JSON Pointer roots and
  selected fields. SQLite BLOB bodies are excluded.
- **Link Read-Only** retains a minimum read-only bookmark for manual refresh.
  **Import into Vault** is a one-time snapshot and removes continuing file
  authority after successful import.
- **Detach** removes continuing file authority while retaining Loki data.
  **Remove Local Data** separately removes the source's Vault generations and
  derived semantic evidence without modifying the original file.
- Publish one complete Vault generation atomically. Cancellation, a busy or
  incoherent WAL snapshot, a stale bookmark, source replacement, malformed
  input, or a budget failure leaves the last accepted generation intact.
- Default SQLite materialization is bounded to 10,000 records, 128 selected
  columns, 16 KiB per text field, 128 KiB per record, 32 MiB aggregate output,
  and 15 seconds of execution.
- Default JSON parsing/materialization is bounded to depth 64, 1,000,000 nodes,
  100,000 records, 128 selected fields, 1 MiB strings, and 32 MiB aggregate
  output. Large numeric tokens preserve their exact spelling.
- The SQLite authorizer denies writes, schema mutation, `ATTACH`, unsafe
  pragmas, extension loading, and arbitrary user- or model-authored SQL. The
  external database is never attached to the production Vault.
- Local-model context is separately opt-in and off by default. It is limited to
  selected admitted evidence and grants no remote-model, web, database, tool,
  publication, or write authority.

SQLCipher/encrypted SQLite, raw SQL, database writes/migrations, remote
databases, remote JSON/reference fetching, automatic refresh, live multiwriter
sync, unlimited files, and BLOB-body indexing are unsupported. See
`ATTACHED_DATA_SOURCES.md` for the complete contract and troubleshooting.

## Required fixture behavior

Connector tests must cover invalid authentication or input, missing permission,
allowlist enforcement, pagination, duplicates, out-of-order data, edits,
deletions, rate limits, cancellation, transient failure, disconnect, credential
deletion, deterministic IDs, provenance, and admitted local-pipeline import.
Tests must also prove that secrets are not logged and forbidden write endpoints
are never invoked.

The historical RC1 runs covered its connector minimums with synthetic
transports and files. The focused 28-class matrix executed 415 tests (412
passed, 3 reviewed environment-gated skips, 0 failed), and the complete native
suite executed 905 tests (895 passed, 10 reviewed skips, 0 failed). The
20-selector disposable application smoke passed without a skip or failure.
Those numbers are not RC3 evidence. RC3 Attached Data tests and the complete
exact-candidate regression/smoke matrix remain pending final execution.

## Optional live Discord smoke

A live account is not required for source-RC acceptance. If the operator later
authorizes a disposable test bot and isolated test server, use this bounded
procedure only after every fixture check is green:

1. Create or select a disposable Discord application/bot and isolated server;
   never use a user token or a personal/community server.
2. Grant only the `bot` installation scope plus View Channels and Read Message
   History for one synthetic channel. Enable Message Content only when the
   smoke is explicitly checking bodies; do not grant Send Messages, Manage
   Messages, reactions, moderation, webhooks, or Administrator.
3. Place a few clearly synthetic messages, one reply/thread, one edit, and
   attachment metadata in the allowlisted channel. Include no real person,
   support case, URL, or attachment body.
4. Connect through the native macOS Sources UI, confirm the privacy disclosure,
   select only that server/channel/thread, and run one bounded manual sync.
5. Verify counts, stable provenance, edit/thread identity, attachment-metadata
   only, local Vault admission, and the absence of DMs or non-allowlisted data.
   Inspect only redacted reason codes/counts; do not capture the token or message
   bodies in evidence.
6. Disconnect and verify local Keychain deletion without a remote write. Then
   separately confirm that retained local data remains until **Remove Local
   Data** is explicitly confirmed.
7. Remove the disposable bot from the test server through Discord's own admin
   surface and delete all task-owned local data. Record only classification,
   counts, and cleanup success.

Any missing disposable credential or provider availability is reported as
`LIVE_DISCORD_SMOKE_UNRUN`; it does not convert fixture coverage into a failure
or a pass.

## Local Email smoke

Email V1 has no live-account boundary. Use task-owned synthetic `.eml` and
`.mbox` files through the file picker, verify import/re-import, restart,
authorization removal, retained-data behavior, and separately confirmed local
deletion. The historical RC1 local smoke exercised these synthetic file paths.
IMAP, Gmail/Microsoft OAuth, and SMTP are deferred rather than treated as an
unrun live Email smoke.
