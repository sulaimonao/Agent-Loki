# Loki Vault Product Contract

## Purpose

Loki Vault is Loki Brief's local-first archive. It stores bounded, normalized history from sources that the Mac user explicitly authorized, provides a manual resumable backfill engine and Slack history adapter behind an explicit entitlement boundary, supports local search, and supplies attributable evidence to deterministic briefings without requiring a Loki cloud database.

The archive stores authorized provider content. It does not store or become the external account.

This document defines the P4 product boundary. A capability is not considered verified merely because it is described here; the P4 checkpoint and test results are the execution record.

## Persistence ownership

- Credentials and refresh tokens remain in the Data Protection Keychain.
- Account identities, permissions, selected containers, policies, cursors, job summaries, storage snapshots, entitlement state, and deletion state belong to the SwiftData control plane.
- Messages, feed entries, revisions, tombstones, provenance, search data, and durable backfill checkpoints belong to the SQLite archive plane.
- Optional Ollama processing remains local and cannot change archive identity, provenance, read state, priority, retention, or deletion state.
- Existing Loki Brief history and presentation remain separate from source evidence.

The P2/P3 SwiftData evidence models remain compatibility sources during P4. Import is additive, idempotent, checkpointed, and does not delete the source records.

## Accounts and providers

Every account uses a stable provider-owned identifier plus a provider kind. Display names are presentation only and never establish identity.

P4 operational providers are:

- Slack workspaces authorized through the existing P3 PKCE and Keychain flow;
- RSS, Atom, and JSON Feed sources already supported by P2.

The account model also reserves explicit provider kinds for Discord, Google, GitHub, Microsoft, Facebook, Instagram, LinkedIn, X, and local import. Those are unavailable or not implemented in P4. They have no fake connection controls and perform no production retrieval.

Multiple accounts for the same provider are supported. Account and container scope must be preserved through archive writes, search, retention, export, backfill, and deletion.

## User workflows

The native Vault destination contains:

- Overview: archive status, integrity state, item and storage totals, active accounts, jobs, and recent failures.
- Accounts: provider identity, selected containers, sync bounds, retention, storage, entitlement requirement, archive deletion, and disconnection controls.
- Backfill: truthful state, bounded usage, oldest reached item, rate-limit wait, Pause, Resume, Cancel, and Skip Container.
- Search: local query, provider/account/container/date filters, attributable results, direct-source actions, and bounded pagination.
- Storage: database/WAL totals, per-account contribution, retention, checkpoint/compact, deterministic export, and deletion.

Unknown provider history never produces a fabricated percentage or exact remaining byte estimate. Progress is expressed with defensible counts, timestamps, and provider wait states.

## Acquisition and ownership

The P4 entitlement boundary is provider-neutral. The deterministic development provider supports tests and previews; no StoreKit, receipt validation, Stripe, Paddle, license server, or production billing provider is integrated. Production P4 therefore reports `provider_not_configured` and pauses new historical acquisition. It does not silently grant a permanent pre-release unlock. The archive engine, Slack adapter, persisted jobs, and ownership controls remain independently testable and usable for already stored data.

An entitlement may stop new premium acquisition when unavailable or expired. It must never prevent the user from:

- reading already stored data;
- exporting existing local data;
- deleting an account archive or all local data;
- disconnecting an account;
- revoking credentials where supported.

P4 entitlement states are `available`, `trial`, `subscribed`, `grace_period`, `expired`, `unavailable`, and `provider_not_configured`.

## Backfill and synchronization

Historical backfill is manual-only and runs only while Loki Brief is open. Every run is bounded by requests, items, elapsed duration, storage growth, and retries. Jobs persist enough state to resume after quit, crash-style reopen, network loss, rate limiting, reauthorization, pause, or partial source failure.

Slack backfill is limited to explicitly selected public or private channels still authorized for the connected workspace. P4 does not retrieve DMs, group DMs, files, canvases, full threads, workspace search results, or unselected channels.

Forward synchronization and historical backfill have separate cursors. P5 scheduled runs may invoke only bounded forward synchronization while the main menu-bar app is running. Backfilled records do not become "new" merely because they were locally inserted later, and the scheduler never starts or resumes a backfill job.

## Search, retention, storage, and export

Search is local-only and independent of Ollama. Queries and result counts are bounded, filters are bound as SQL parameters, FTS5 is used when available, and a deterministic LIKE fallback preserves the same domain contract.

Retention is account- or container-scoped, transactional, and separate from credentials and account connection state. Deletion removes obsolete revisions and search entries while preserving unrelated accounts.

Storage reporting distinguishes the main database, WAL, shared-memory sidecar, total archive bytes, freelist bytes, item/revision/tombstone counts, time bounds, and per-account contribution. Provider-side history size remains unknown unless the provider supplies a defensible estimate.

Exports use deterministic `.lokivault` JSONL with a manifest, schema version, export time, scope, sorted records, provenance, tombstones, and checksums. Full, account-scoped, and date-bounded export are supported. P4 exports are local and unencrypted; import/restore is deferred.

## Privacy and local-at-rest statement

Archive content never goes to a Loki-operated server. SQLite content is not application-level encrypted. Local protection relies on App Sandbox containment, restrictive POSIX permissions, the macOS user account, optional FileVault, and Keychain isolation for credentials.

No trace may contain message/feed text, search terms, channel names, account display names, source URLs, export contents, credentials, tokens, prompts, model bodies, or raw provider responses.

## P4 exclusions

P4 does not include background scheduling, login helpers, notifications, scheduled delivery, production billing, cloud synchronization, cloud models, semantic/vector search, attachment downloads, article scraping, new production providers, release signing, notarization, packaging, or public distribution.

## Acceptance boundary

P4 is accepted only when the universal native build, complete native suite, focused database/search/import/backfill/Slack-adapter/retention/export/entitlement/migration tests, Keychain smoke, UI lifecycle checks, privacy scans, and inherited Node 22 regressions pass. A live Slack backfill is conditional on external configuration and explicit operator authorization.

## P5 integration boundary

P5 reads newly eligible evidence and writes authorized forward-sync evidence through the existing idempotent Vault path with account isolation, provenance, cursor separation, retention, tombstones, and search consistency. Schedule, occurrence, run, source-result, and notification metadata remain in SwiftData; P5 creates no second delivery/archive database. It adds no login helper, LaunchAgent, daemon, cloud scheduler, remote push, scheduled historical backfill, billing provider, new production connector, semantic search, attachment retrieval, article scraping, or P6 release work.

## P6 early-access policy

P4's fail-closed production state remains part of the sealed P4 historical record. Loki Brief 1.0 Early Access intentionally supersedes only the production composition: implemented Vault acquisition, retention, search, storage, export, account, and scheduled-source capabilities are included without payment or a Loki account. Future features remain unoffered. The provider-neutral protocol and every existing data-ownership guarantee remain unchanged; no billing provider, receipt, license, or cloud entitlement is introduced.
