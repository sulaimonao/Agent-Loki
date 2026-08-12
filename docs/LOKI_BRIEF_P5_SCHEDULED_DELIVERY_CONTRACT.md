# Loki Brief P5 scheduled-delivery contract

## Scope

P5 adds scheduled foreground-process synchronization, one primary daily brief schedule, native local notifications, run history, missed-run reconciliation, and optional launch at login. The main Loki Brief application is the only scheduler host. P5 adds no helper application, LaunchAgent, daemon, XPC service, cloud scheduler, remote notification service, billing provider, or release/distribution work.

The operating truth is explicit:

- while Loki Brief is running, authorized schedules may execute;
- launch at login can reopen the main app on subsequent logins when the user explicitly enables it and macOS approves it;
- closing the main window leaves the menu-bar app running;
- explicitly quitting Loki Brief pauses delivery until the app is opened again;
- sleep, logout, low-power deferral, and termination never imply hidden execution.

## Scheduler authority

One actor owns one cancellable waiting task and a monotonically increasing scheduler epoch. Settings, wake, time-zone, system-clock, and power changes cancel the prior wait, increment the epoch, recompute recurrence, and arm at most one replacement. The scheduler never busy-polls and never assumes that sleeping for 86,400 seconds represents a local day.

The scheduler persists an occurrence claim before source activity. A required occurrence key is derived from the schedule identifier, intended local date, intended local time, resolved time-zone identifier, and recurrence version. A semantic slot key excluding the zone identifier prevents a time-zone change from producing two successful briefs for the same intended daily slot. A failed occurrence may retry; a successful slot cannot complete twice.

## Recurrence and missed runs

P5 supports one enabled/disabled daily schedule, selected weekdays, a local delivery time, follow-system or fixed time zone, and the policies `skip`, `runWhenAppReturns`, and `runWithinGraceWindow`. The default policy is `runWithinGraceWindow` with a six-hour grace window.

Recurrence uses a Gregorian calendar and an explicitly resolved time zone:

- a nonexistent spring-forward time resolves to the first valid later time on the intended local day;
- a repeated fall-back time uses the first physical occurrence;
- the intended local date is always persisted with the actual resolved instant;
- a clock or time-zone change recomputes without reopening a completed semantic slot.

Launch and wake reconciliation consider only the newest eligible missed occurrence. Older missed days do not generate a chain of catch-up briefs. An ineligible occurrence is recorded as skipped with a stable reason code.

## Scheduled run plan and budgets

Every run captures one immutable plan before network activity. It contains the occurrence, enabled feed sources, connected and selected Slack accounts/channels, source request limits, total/item/storage/retry limits, Ollama consent policy, notification policy, entitlement decisions, and privacy mode. Persisted plan metadata contains identifiers, counts, decisions, and hashes only—never credentials, prompts, raw payloads, source text, URLs, or model output.

Initial bounds are:

- total duration: five minutes;
- bounded feed and Slack request counts;
- bounded new archive items and storage growth;
- bounded transient retries;
- bounded Ollama duration.

Retry windows cannot exceed the remaining run budget. A provider whose delay exceeds the budget becomes a truthful partial/deferred source result and cannot hold the deterministic brief indefinitely.

## Source and Vault behavior

Feeds reuse P2 HTTPS, SSRF, redirect, conditional-request, response-size, cancellation, and partial-success controls. Scheduled refresh never fetches article pages.

Slack reuses the P3 selected-channel connector and P4 archive adapter. It processes connected workspaces and selected public/private channels already authorized by the user, uses forward cursors only, and never starts historical backfill, DMs, files, or threads. Workspaces execute sequentially through the existing single-run Slack coordinator. Missing external Slack configuration produces an unavailable source result while feeds and local evidence continue.

Accepted feed and Slack evidence enters Loki Vault through the existing idempotent archive path with provenance, cursor separation, account isolation, tombstones, retention, and search consistency. P5 creates no second archive database.

## Deterministic brief and Ollama

After source work, the run selects newly eligible Vault evidence, excludes historical-backfill records from “new” status, applies deterministic ranking and ordering, preserves attribution, and persists the authoritative brief. At most one optional Ollama presentation attempt follows deterministic selection.

Scheduled Ollama is off by default. It requires global scheduled-generation consent, existing per-workspace Slack consent for Slack evidence, the fixed loopback provider, a selected installed model, and the existing input/output bounds. Disabled, unavailable, missing-model, timeout, cancellation, or invalid output states preserve deterministic presentation. Loki Brief never starts Ollama, pulls a model, switches to a cloud model, or lets generated text alter evidence identity, priority, ordering, links, read state, synchronization state, or run truth.

## Launch at login

`SMAppService.mainApp` is the only login mechanism. Registration, unregistration, and opening Login Items settings require explicit user action. Stored preference and actual service state remain separate. The UI maps the real system states `notRegistered`, `enabled`, `requiresApproval`, and `notFound`, plus local `unsupported` and `error` states. Tests inject a fake and never register the app.

## Notifications and privacy

P5 uses `UNUserNotificationCenter` for local notifications only. Permission is requested only from the explicit enable-notifications action, never at first launch, migration, startup reconciliation, or during a scheduled run. The app refreshes actual authorization state and represents `notDetermined`, `denied`, `authorized`, `provisional`, and `ephemeral`, plus local `unsupported` and `error` states.

Default notification content is privacy-minimal: a fixed completion title and bounded item/source counts. Summary mode may add bounded run-result language but never source text, Slack excerpts, workspace/channel/account/author names, email addresses, URLs, search terms, prompts, or model output. The stable request identifier is derived from the occurrence key and is backed by persisted delivery idempotency. System acceptance is recorded as submitted, not as proof that the notification was seen.

Notification responses validate an allowlisted category plus brief and occurrence identifiers, route only to an existing persisted brief, open Today, and activate Loki Brief. Responses received before model/window readiness are buffered once. Delete All removes pending and delivered notifications and invalidates late callbacks.

## Persistence and recovery

The SwiftData V6 control plane adds schedule, occurrence, scheduled-run, source-result, and delivery records through an additive V4-to-V5-to-V6 migration. The migration chain retains both the exact pre-seal P3 Slack-evidence shape that existed before the optional edit timestamp and the exact pre-plan-metadata V5 scheduled-run shape, allowing those recognized stores to advance without reset. It stores intended and actual timing, trigger, stage, bounded counts, privacy-safe immutable plan metadata, brief identifier, notification result, stable failure reason, partial state, and next occurrence. A migrated legacy V5 run receives an explicit unavailable metadata sentinel because its discarded plan decisions cannot be reconstructed truthfully. It stores no credentials, source text, prompts, raw responses, private notification bodies, or full provider errors.

At launch, nonterminal runs become interrupted with a stable termination reason. Retry is allowed only while the schedule remains enabled, the semantic slot has no successful completion, the occurrence is eligible under catch-up policy, and source operations remain idempotent. Recovery never assumes completion and never duplicates evidence or notification delivery.

## Power, network, and deletion

Before sleep, Loki Brief stops starting new work and either completes a narrowly bounded near-finished transaction or cancels and persists interruption. Wake recomputes and permits at most one catch-up. “Pause in Low Power Mode” defaults on; deferral is recorded and reconciled when power state permits. P5 adds no power assertion or hidden always-on network monitor.

Disabling a schedule cancels its waiting task without deleting history or disconnecting accounts. Unregistering launch at login does not alter the schedule preference. Account disconnect removes the account from future plans, cancels its active work, preserves other source results, and rejects late completion. Delete All cancels scheduler/source/Ollama/notification work, advances epochs, removes all P5 control records and notifications, and prevents callbacks from recreating data.

## Entitlements and P6 boundary

P5 preserves the provider-neutral entitlement layer for daily scheduling, background forward synchronization, multiple-account scheduled synchronization, and scheduled local-model processing. Deterministic fixtures may exercise entitlement states in development/tests. P5 did not permanently classify scheduling as free or paid and does not weaken access to existing briefs, Vault search, export, deletion, credential revocation, or existing manual operations.

P6 explicitly classifies implemented local scheduling and processing as included in the free Loki Brief 1.0 Early Access release. It preserves the provider-neutral boundary for future features, adds no billing provider, and owns only private release hardening, Developer ID distribution signing, notarization, stapling, packaging, and private draft-release proof. Public distribution remains separately unauthorized.
