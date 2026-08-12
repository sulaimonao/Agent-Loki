# Loki Vault Backfill Contract

## Scope

P4 provides manual, foreground-only, provider-neutral historical backfill. The user explicitly starts or resumes a job while Loki Brief is open. P4 creates no launch agent, background helper, schedule, login item, or notification delivery.

Slack is the first production backfill adapter. Existing feed evidence uses the import contract rather than arbitrary website crawling.

The shipping P4 composition intentionally has no production billing or entitlement provider. It reports `provider_not_configured`, disables Start/Resume for new historical acquisition, and leaves existing archive read/export/delete/disconnect controls available. Deterministic entitlement grants are test/preview injection only; this is not a hidden production unlock.

P6 retains that statement as P4 historical truth but supersedes the current production composition: Loki Brief 1.0 Early Access includes implemented historical backfill without payment or a Loki account. The same budgets, ownership controls, provider-neutral boundary, and future-unoffered state remain authoritative.

## Durable job model

A job records:

- stable job and provider identity;
- creation/start/update/finish times;
- state and explicit stop reason;
- next retry time where relevant;
- generation used to reject late completions;
- failed-source count;
- request, item, duration, storage, and retry budget;
- per-run usage;
- ordered account/container source checkpoints.

Each source checkpoint keeps account and container identity, immutable forward cursor, historical cursor, historical time boundary, exhaustion state, and bounded failure reason.

## States

The engine exposes queued, running, pausing, paused, resuming, waiting-for-rate-limit, reauthorization-required, provider-unavailable, canceling, canceled, partially-completed, completed, and failed states.

Every stop has a stable reason code. A budget stop is `partially_completed`, not success. Provider and account failures remain isolated where safe.

## Run budgets

Every invocation is bounded by:

- maximum provider requests;
- maximum accepted items;
- maximum elapsed duration;
- maximum archive growth;
- maximum retries.

Usage is persisted. Resume begins a new bounded invocation without losing the durable historical cursor. The engine never runs an unbounded "download everything" loop.

If a provider page is larger than the remaining item/storage budget, the engine must not advance beyond uncommitted items. The adapter must honor the requested page size or preserve a replayable boundary.

## Persistence and crash recovery

`VaultBackfillPersisting.commit` atomically writes accepted archive items, job state, and checkpoint. A cursor is never acknowledged before its items commit.

On application reopen, transient persisted states such as running, resuming, pausing, or canceling are reconciled to a safe resumable or canceled state with an explicit recovery reason. In-flight credentials and raw provider responses are never persisted.

Pause, cancel, account deletion, and disconnect advance the job generation and cancel relevant provider work. Account deletion also removes matching durable job/checkpoint blobs in the same archive transaction while preserving jobs for unrelated accounts. Any later page from an older generation is logged as skipped and cannot update archive content or cursors.

## Slack authorization boundary

Slack backfill reuses the P3 connection, rotating Keychain credential provider, selected-channel records, identity validation, and fixed-authority API client. It creates no second OAuth/token implementation.

Eligible history is limited to:

- an explicitly connected workspace;
- enabled, explicitly selected public or private channels;
- channels still accessible under granted user scopes;
- messages returned by the authorized `conversations.history` boundary.

The adapter rejects DMs/group DMs and does not call files, canvases, replies/full threads, workspace search, join, posting, or reaction APIs. It does not persist raw Slack envelopes.

## Cursor rules

Forward and historical cursors are independent. Historical retrieval uses the provider cursor and/or oldest time boundary supplied by Slack. Successful historical commits may update only the historical cursor.

For each account/container, durable state can report newest/forward position, oldest/historical position, last success, last rate limit, last failure, and exhaustion.

## Rate limits and retries

Slack HTTP 429 `Retry-After` is authoritative. The job persists `waiting_for_rate_limit` with the retry time, and the UI reports the wait without bypassing it. Accounts are never rotated to evade limits, and channels remain sequential under the run budget.

Transient retry counts contribute to the job retry/request budgets. Reauthorization, provider unavailable, and source unavailable remain distinct outcomes.

## Normalization

Slack pages normalize to provider-neutral archive items while preserving workspace/account, channel/container, message identity, author, timestamp, edit state, direct mention, reply metadata, permalink when available, provenance, and bounded text. Files and attachment bodies are excluded.

Deleted or inaccessible provider items become tombstones with prior-content purge state. Stable hashes suppress duplicates and unchanged revisions.

## User controls

The Vault UI provides Start, Pause, Resume, Cancel, and Skip Container. It reports counts, oldest item reached, elapsed time, requests, storage growth, and rate-limit state. It never displays a percentage when total provider history is unknown.

## Required deterministic proof

Focused tests cover enqueue/run, pause/resume/cancel, crash-style reopen, persisted checkpoint, forward/historical separation, every budget, rate limiting, reauthorization, provider/source unavailable, partial completion, account isolation, late-result rejection, cursor-gap prevention, and Slack scope/normalization exclusions.

A live Slack smoke is optional and requires completed external configuration plus explicit operator authorization. It is bounded to one workspace, one selected non-sensitive channel, two requests, and 30 messages, with no content printed.
