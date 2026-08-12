# Loki Vault Privacy and Retention

## Local-first privacy boundary

Loki Vault stores explicitly authorized, bounded source history on the user's Mac. Archive content is not sent to a Loki-operated server. There is no telemetry or analytics SDK.

Credentials remain in the Data Protection Keychain. SQLite and SwiftData contain no access token, refresh token, authorization code, verifier, client secret, or Keychain envelope.

## Local-at-rest limitation

Vault SQLite content and `.lokivault` exports are not application-level encrypted in P4. Protection relies on:

- App Sandbox containment;
- `0700` archive-directory and `0600` database/export permissions where supported;
- the current macOS user account and filesystem permissions;
- macOS disk protection such as FileVault when enabled;
- Data Protection Keychain isolation for credentials.

The product and UI must not describe SQLite or exports as password-encrypted.

## Data admitted to Vault

Vault may store bounded normalized source content, title, author reference, provider/account/container/item identifiers, timestamps, read/direct-mention state, thread/reply metadata, permalink, content hash, provenance, bounded revisions, cursors, jobs, tombstones, and storage statistics.

Vault does not store full raw API responses, credentials, files, remote images, complete attachment bodies, article pages, unbounded HTML, scripts, cookies, private prompts, Ollama context buffers, hidden reasoning, or generated thinking output.

Only explicitly selected Slack channels are eligible. DMs, group DMs, files, canvases, full threads, workspace search, and unselected channels are excluded.

## Trace redaction

Logs may include stable event and reason codes, provider kind, hashed account/container/record/job identifiers, state, bounded counts, byte counts, duration, retry count, and integrity classification.

Logs must never include:

- message or feed text;
- search terms or search snippets;
- account/workspace display names;
- channel/container names;
- source URLs or permalinks;
- export content;
- tokens, credentials, authorization material, or secrets;
- prompts, model inputs, or model output bodies;
- raw provider responses.

Trace metadata is allowlisted, bounded, and encoded as structured JSON with trace/span/parent relationships. Search logging records token/result counts rather than query text.

## Retention policies

The control plane represents recent-only, 30-day, 90-day, one-year, unlimited, and custom policy choices. The archive engine receives the resolved account/container-scoped age and record limits.

"Unlimited" remains bounded by available local storage, an operator-defined cap, provider access, database safety limits, and bounded execution. It is not a promise of complete provider history.

Retention execution is transactional and scoped. It:

- tombstones and purges expired current content;
- removes FTS rows through database triggers;
- removes revisions with deleted records;
- prunes old tombstones according to policy;
- refreshes storage reporting;
- preserves unrelated accounts and containers;
- leaves credentials and provider connection state unchanged.

Entitlement logic may prevent new extended retention acquisition. It never blocks reading, export, or deletion of already stored data.

## Account archive deletion

Delete Local Archive performs the following bounded sequence:

1. invalidate and pause account jobs;
2. cancel account-scoped provider requests;
3. reject late completions;
4. transactionally delete account records, revisions, FTS rows, permitted tombstones, provenance, cursors, runs, jobs, and statistics;
5. refresh storage totals;
6. preserve other accounts, providers, settings, and credentials.

Disconnect Account removes credentials and connection authority without silently deleting the local archive. Disconnect and Delete Everything combines both operations after explicit confirmation.

## Delete All Local Data

Delete All requires explicit confirmation and a cancellation/late-result guard. It closes and checkpoints Vault before removing:

- the database, WAL, and SHM files;
- export staging files;
- account controls, jobs, cursors, statistics, and deletion records;
- P1-P3 SwiftData evidence and settings under the existing product contract;
- Slack Keychain credentials;
- preview data where the existing deletion contract requires it.

The operation never deletes repository/source files or unrelated system credentials. It does not automatically recreate the archive or reseed fixtures during the same operation. Partial cleanup is reported with a stable reason rather than represented as success.

## Export privacy

Exports include only the selected archive scope and deterministic metadata/checksums. Credentials, Keychain values, secrets, raw responses, prompts, hidden reasoning, signing material, and provisioning profiles are excluded.

P4 exports are local and unencrypted. Users should store or transmit them according to the sensitivity of the archived source content.

## Provider revocation and source deletion

Local deletion and credential removal must work offline. Remote provider revocation uncertainty remains visible and does not prevent local cleanup.

Known provider deletion produces a tombstone. When prior content existed, Vault purges it and records that fact; a deletion observed before any content was archived truthfully records that there was no prior local content to purge. Vault does not retain deleted content indefinitely merely to preserve revision history.

## Verification requirements

Privacy verification includes trace-sentinel tests, secret and generated-artifact scans, account/container isolation tests, retention/FTS cleanup, export exclusion checks, offline deletion, Delete All sidecar removal, late-result rejection, close/reopen, and user-facing local-at-rest wording review.
