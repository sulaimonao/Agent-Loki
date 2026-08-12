# Privacy

Agent Loki is local-first. The application has no required Loki cloud account,
telemetry, analytics, advertising, crash upload, or remote logging service.

## Data stored locally

Depending on enabled features, Loki Brief stores settings, source metadata,
brief history, schedules, chat records, connector state, provenance, and
bounded source content in local SwiftData or SQLite stores. Semantic vectors
are derived, rebuildable local data. User-requested exports are not encrypted
by the application; use FileVault and trusted storage.

Attached Data Sources may store a minimum read-only security-scoped bookmark,
privacy-safe file identity, selection, receipts, and bounded normalized Vault
records. **Link Read-Only** retains file authority for manual refresh.
**Import into Vault** removes continuing file authority after a successful
one-time import. Private absolute paths and raw database/JSON content must not
enter diagnostic logs.

Credentials are stored in the macOS Keychain or ignored local configuration.
They must not enter source control, logs, exports, semantic indexes, or support
reports.

## Network activity

Network access occurs only for an explicit feature boundary:

- public HTTPS feed retrieval;
- user-authorized selected-channel Slack reads;
- user-authorized Discord bot reads through the native read-only connector;
- fixed numeric-loopback Ollama inference on the same Mac;
- separately enabled Ollama Web Search or Web Fetch after disclosure, preview,
  and credential checks; and
- signed update checks only when a public feed is configured and the user
  enables or manually requests a check.

Selecting a local SQLite database or JSON document does not itself create
network activity. Attached Data does not support remote databases, remote JSON,
URLs, or reference fetching.

Support Email V1 parses user-selected local files without sending email.
IMAP and SMTP are outside this release.

## Connector content

Imported content is treated as untrusted evidence. Connector selection,
credential presence, semantic-index source selection, search filtering, and
external writes are separate authorities. Connecting a provider never silently
authorizes indexing, model context, publication, or another provider action.

Attached Data uses the same separation. Its **Allow this source in explicitly
rebuilt local-model indexes** control defaults off and applies only to selected,
admitted source evidence under the existing local-model boundary. It does not
authorize a cloud model, web research, remote database access, tool use,
publication, or any external write. Connecting or importing a file never
silently transmits it to a remote provider.

SQLite BLOB bodies are excluded. JSON and SQLite reads are bounded; rejected,
canceled, busy, stale, or changing inputs do not publish a partial replacement.
The last complete accepted Vault generation remains intact.

Discord attachments default to metadata only. Support Email attachment bodies
are ignored by default. No connector downloads attachment bodies silently.

## Legacy TypeScript Gateway/moderation runtime

The inherited root TypeScript Discord runtime is separate from Loki Brief. It
uses the Discord Gateway, is write-capable, and has its own environment
configuration and local database. Running it can send Discord responses and,
after separate approval, moderation actions. Its behavior must not be described
as the native macOS read-only REST connector.

## Logs and support

Logs use bounded events, status, reason codes, counts, and non-content
identifiers. They must exclude credentials, raw provider payloads, message or
email bodies, prompts, model output, attachment bytes, database rows, and
private filesystem paths. Follow `SUPPORT.md` before sharing diagnostics.

## Deletion

Users can disconnect sources and remove associated local data. Deleting the app
bundle alone may leave its sandbox container and Keychain items; follow the
current uninstall documentation for complete removal.

For Attached Data, **Detach** removes continuing file authority while retaining
admitted Loki data. **Remove Local Data** separately removes the source's Vault
records, revisions, tombstones, and derived semantic evidence without changing
or deleting the original file. An imported snapshot has already dropped its
continuing bookmark after a successful import.
