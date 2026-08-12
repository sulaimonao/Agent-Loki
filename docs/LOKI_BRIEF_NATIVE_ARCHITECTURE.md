# Loki Brief Native Architecture

## Placement

Agent Loki is the analyst-facing conversational layer over evidence already authorized inside Loki Brief. The inherited TypeScript runtime, including Discord and Ollama support, remains separate and untouched. `macos/LokiBrief` is the native product surface and owns briefs, sources, Vault, schedules, chat, authorization, presentation, persistence, and lifecycle safety. Ollama hosts local inference only. No external reasoning, control, or orchestration service is required or executed by P8.

## Native target

`LokiBrief.xcodeproj` contains a SwiftUI macOS 14 application and XCTest unit-test target. Through P6R it used Apple system frameworks and the system SQLite library only. P6U authorizes one exact external dependency: the Sparkle 2.9.4 Swift Package Manager binary product. It adds Sparkle's bundled Installer XPC service, but no app-owned helper, embedded WebView, incoming listener, or server component. `MenuBarExtra` and `WindowGroup` share an injected `AppModel`, SwiftData `LocalStore`, actor-isolated Vault services, and native Agent Loki state. Networking executes outside the main actor through bounded mockable feed, fixed-loopback Ollama, fixed-authority Slack, token-free HTTPS update, and disabled-by-default fixed-authority Ollama web-research transports. Local model routes are `/api/show`, `/api/chat`, and `/api/embed`; web research is a distinct authenticated `ollama.com` boundary with strict public-HTTPS target policy. Slack authorization uses the system browser through `ASWebAuthenticationSession`; one-time verifier/state material stays actor-isolated and in memory. Awaited progress callbacks plus operation/epoch guards reject late results after cancellation, consent changes, deletion, disconnect, or update suspension.

## Contracts

- Brief domain: `Brief`, `BriefSection`, `BriefItem`, priority/status, explicit source, provenance, generation record, timestamps, read state, source/generated origin, and unavailable message.
- Source domain: P2 feed contracts remain unchanged. P3 adds explicit Slack workspace, credential-metadata, channel-selection, message-evidence, cursor, sync, rate-limit, and error types. Slack retrieval is read-only, user-token-only, selected-channel-only, manual, sequential, one page per channel, and capped at 15 messages.
- Authorization domain: RFC 7636 S256 PKCE, exact Slack-accepted private-use callback `com.agentloki.lokibrief://oauth/slack`, a testable system-browser adapter, public-client code/refresh exchange without a secret, `auth.test` identity binding, and serialized rotating credential refresh.
- Credential domain: Security.framework Data Protection Keychain adapters
  store one versioned Generic Password envelope per Slack workspace/user and a
  separate Agent Loki Web Research envelope under its own service/account.
  SwiftData contains only non-secret connection, freshness, and consent
  metadata. P8 source verification uses a fake credential store and no live
  key; signing/install remains outside P8.
- Provider domain: the fixed-loopback native Ollama provider owns health, installed-model discovery, explicit selection, bounded structured generation, cancellation, validation, fallback, provenance, and safe trace events. Deterministic generation remains independent.
- Model-capability domain: P8 separates discovery, recommendation, selection,
  assessment, role readiness, staleness, partial compatibility, and
  unavailability for primary, text fallback, vision, embedding, and brief
  summary. Names and installed state never establish readiness.
- Multimodal/reasoning domain: Ollama thinking, visible content, and tool calls
  remain separate; image-file bytes are locally normalized and metadata
  stripped before fixed-loopback submission.
- Semantic/research domain: a separate system-SQLite derived index owns
  deterministic chunks/vectors/generations. P8F separates index-build source
  authority from search-result filters and future connector-ingestion
  authority. Every foreground rebuild carries a nonempty closed source
  allowlist; only selected source adapters may run, and excluded adapters
  perform zero reads. Vault remains behind its permission-filtered snapshot
  boundary and also requires explicit build selection. No automatic or
  background indexing occurs. A disabled-by-default fixed external provider
  owns bounded web evidence and never canonical data.
- Chat domain: conversations, user-visible messages, context scopes, answer classifications, evidence references, tool receipts, generation provenance, failures, privacy settings, and per-workspace evidence policies are explicit native value types. The compact Today panel and full Chat workspace share the same local contracts.
- Read-only tool boundary: the model proposes a request from the exact closed
  local registry or, after every independent P8 gate passes, one exact
  preview-bound `web_search` or `web_fetch` request. The application validates
  tool name, exact arguments, account/container scope, time/result bounds,
  cancellation, authorization, source policy, and the separate research
  credential/disclosure/consent/URL boundary before invoking the corresponding
  façade. Vault reads participate in the existing foreground-operation
  barrier. No SQL, filesystem, shell, generic network, provider-write,
  delivery-write, or update-write method is exposed.
- Context and evidence boundary: system policy, application schemas, conversation tail, current user request, and bounded evidence remain separate authority layers. External source text is typed untrusted evidence, never instruction. Deterministic selection applies consent, item/text/token ceilings, preserves attribution after truncation, and yields a citation allowlist.
- Engine boundary: P1 preview and P2 feed-only behavior remain available. The P3 mixed deterministic engine places Slack in collaboration by default, admits it to attention only through explicit explainable rules, and remains authoritative over evidence, identity, priority, ordering, links, selection, and fallback.
- Workflow boundary: feed and Slack refresh coordinators stay independent. Slack has per-workspace epochs and truthful queued/waiting/rate-limited/partial/cancelled states. Ollama receives feed evidence under existing consent and Slack evidence only for specifically consented workspaces.
- Vault domain: stable provider-owned account/container/item identifiers, separate forward and historical cursors, bounded archive items/revisions/tombstones, local search, retention, storage, export, entitlement, and deletion contracts are provider-neutral. Slack and feeds were the operational adapters at the historical P4 milestone; the source RC adds native Discord and local Email admission through the same provider-neutral boundary.
- Backfill boundary: jobs are manual-only, actor-isolated, resumable from persisted checkpoints, sequential per provider budget, and bounded by requests, items, duration, storage growth, and retries. Rate-limit, pause, cancel, partial, reauthorization, and unavailable states remain truthful. P4 historically shipped with a fail-closed provider; P6 composes the explicit Loki Brief 1.0 Early Access provider so implemented local acquisition is available while future features remain unoffered. Ownership controls never depend on acquisition state.
- Update boundary: provider-neutral channel, state, availability, policy, check-result, install-readiness, failure, and receipt types sit above a Sparkle adapter. Stable is the persisted default and accepts only stable candidates; explicitly selected beta/internal channels may also receive stable candidates. The state model distinguishes check, availability, download, readiness, install, relaunch, installed, and recovered outcomes. Stable failures are intentionally bounded rather than separate DNS/TLS/HTTP/malformed-feed types. Traces are authoritative for feed/archive/install/relaunch validation; a receipt records only the bounded replacement/relaunch outcome. Sparkle-specific values do not become persistence or product-policy authority.

## Persistence and dependencies

`LocalStore` owns an injected SwiftData `ModelContainer`; hosted tests use isolated in-memory stores and migration tests use temporary on-disk stores. The additive chain preserves every predecessor: V4 added non-secret Vault control metadata, V6 added scheduled delivery, V7 added local civil-day truth, P7 V8 added Chat, P8 V9 added explicit model-role and P8 control state, and the source-RC V10 stage adds connector status, sync-receipt, and read-only Email bookmark metadata. Large source history remains in the separate Vault SQLite archive; semantic chunks and vectors live in a different rebuildable SQLite index bound to model/digest/dimension/chunker/normalizer generation metadata plus the P8F source-authority version, canonical allowlist/hash, and per-adapter contract versions. Chat and semantic storage reference source provenance instead of duplicating complete records. Migration failure preserves the original store and exposes a truthful degraded state; a legacy derived generation without source-scope identity is preserved but non-queryable until explicit rebuild. Credentials, authorization headers, raw responses, system/developer prompts, hidden reasoning, image bytes, full fetched pages, and private provider payloads never belong in Chat persistence, SwiftData metadata, logs, or the semantic index.

## Successor boundaries

P4 owns local archive and manual foreground synchronization. P5 adds while-running scheduling, notifications, and main-app launch at login. P6 remains paused; P6R sealed local-calendar behavior; P6U owns secure-update foundations. P7 owns native Chat. P8 owns explicit model roles, private reasoning transport, image-file input, embeddings/semantic retrieval, opt-in Ollama web research, and the original inert connector-ingestion envelope. The verified open-source source-RC lane supplies bounded native Discord REST ingestion and local `.eml`/`.mbox` Email import through that envelope. P9 Workbench, verified writes, commercial work, DMs, posting, moderation, IMAP, production update publication, and public binary distribution remain outside this source-RC boundary.

## Foundation invariant

The target retains App Sandbox, outgoing-client networking, and one application-derived Keychain access group. P6U adds only Sparkle's required temporary mach-lookup names; the source RC adds user-selected read-only file access and app-scoped security bookmarks for local Email import. Feed safety is unchanged; local Ollama remains numeric loopback; Slack remains fixed to `slack.com`; native Discord is fixed to bounded HTTPS GET endpoints under `discord.com/api/v10`; optional research is fixed to authenticated `ollama.com` endpoints and validates the fetched target separately. There is no incoming server, broad ATS exception, app-owned WebView, remote-push entitlement, app-owned helper, analytics SDK, Discord posting endpoint, cloud model, or external control execution. Traces retain stable privacy-safe reason codes and counts, never secrets, raw messages, answer text, evidence, tool arguments, prompts, image bytes/paths, fetched pages, private URLs, hidden reasoning, or user paths.

## P8F semantic source-authority architecture

The semantic controller exposes three independent state surfaces: selected
sources for the next manual rebuild, source kinds present in the active
generation, and current search-result filters. The closed source-kind domain is
briefs, schedules, final Chat messages, Vault records, Slack records, and
future connector records. First use selects no build sources. Slack and Vault
remain off until the operator explicitly selects them; search-filter state is
never copied into build state.

Each source family has a declared adapter contract. The controller dispatches
only adapters named by the request’s canonical allowlist, so an excluded
adapter cannot read, preview, or count its canonical store. Prepared records
retain their stable source kind and adapter evidence through a second
validation boundary at the derived index. Unknown, missing, unauthorized, or
adapter-mismatched kinds abort the candidate generation before publication.
At the P8F seal, connector adapters were inert because authentication,
pagination, and history backfill were deferred. The source RC supersedes that
historical limitation for the bounded native Discord and local Email adapters;
semantic indexing still requires its separate explicit source selection.

The index builds outside the active generation. Publication is one final
validated transition after adapters, authority checks, chunking, embedding,
count reconciliation, identity persistence, cancellation, and lifecycle epoch
checks all pass. Failure or cancellation leaves the prior active generation
unchanged. Source-scope unknown, changed, revoked, violated, or
rebuild-required states block lexical, semantic, and hybrid retrieval; a
search-filter change alone does not stale the generation. Delete All removes
active and incomplete derived generations and their authority metadata without
opening or mutating canonical source stores.

## P5 additive architecture

P5 keeps the same single native target and adds no helper process. One actor-owned `BriefScheduler` lives in the main menu-bar application, owns one cancellable wait, persists occurrence claims, and recomputes on launch, wake, settings, clock, time-zone, and power changes. One scheduled/manual coordinator captures an immutable budgeted plan, performs bounded feed and sequential Slack forward synchronization, reconciles Loki Vault once, creates one deterministic brief, optionally attempts one consented Ollama presentation, persists run truth, and submits at most one local notification.

SwiftData V6 preserves every P1-P4 entity and additively stores schedules, semantic/zone-bearing occurrence identity, scheduled runs, source results, immutable privacy-safe plan metadata, and delivery records. Its migration chain retains the exact pre-plan-metadata V5 scheduled-run shape so an already-migrated V5 store advances without reset. `SMAppService.mainApp` is the only launch-at-login mechanism. UserNotifications remains local-only, requires an explicit settings action, defaults to privacy-minimal counts, and adds no remote-push entitlement. Closing the last window leaves the menu-bar process running; explicit Quit pauses scheduling until the app is opened again.

P5 observability uses linked trace/span IDs, stable reason codes, durations, bounded counts, and hashed identifiers for scheduler lifecycle, occurrence reconciliation, stages, source outcomes, fallback, persistence, notification, login registration, wake/power deferral, cancellation, and interruption recovery. It never logs source text, workspace/channel/account names, URLs, notification bodies, prompts, credentials, or model output.

## P6 release architecture

Loki Brief 1.0 Early Access retains the provider-neutral entitlement protocol. `LokiBriefEarlyAccessEntitlementProvider` exhaustively includes implemented local archive, search, retention, export, scheduling, forward-sync, and consented local-processing features. Future advanced processing remains explicitly unavailable. No StoreKit, receipt, payment, license, account, or cloud-entitlement component is linked.

At the historical P6 gate, the Release target was version 1.0.0/build 2,
bundle `com.agentloki.LokiBrief`, minimum macOS 14.0, and universal
`arm64`/`x86_64`. It selected the approved AppIcon, Hardened Runtime, no
injected debug entitlements, and the existing sandbox/network/app-specific
Keychain entitlements. Xcode performed its standard archive step, then a
task-local Developer ID export configuration re-signed the distributable app.
The profile, certificate, credentials, archive, DMG, manifest, checksums, and
notarization outputs remained outside Git.

P6 remains paused. Its accepted notarized artifact is superseded private engineering evidence and is not a P6U baseline or publication artifact.

## P6U secure-update architecture

P6U pins Sparkle 2.9.4's binary product. The already-networked sandboxed host enables `Installer.xpc` with `SUEnableInstallerLauncherService`, leaves the framework-bundled `Downloader.xpc` service disabled, and carries only the `-spks` and `-spki` mach-lookup exceptions required for installer communication. The app target includes `@executable_path/../Frameworks` in `LD_RUNPATH_SEARCH_PATHS` so exported builds load the embedded Sparkle framework outside XCTest. Xcode's final Archive and Export flow distribution-signs the framework and nested service/helper code; ad-hoc package signatures and `Code Sign on Copy` alone are not proof.

The Sparkle adapter resolves a token-free HTTPS appcast for stable, beta, or internal policy and maps updater/delegate/standard-user-driver callbacks into provider-neutral state. Automatic checks start disabled and change only by explicit user preference. Automatic installation remains disabled. Manual `Check for Updates…` uses `canCheckForUpdates`. Sparkle's standard update window owns live download, approval, install, and relaunch controls; Loki Brief records download start and the validated 100-percent boundary and reflects bounded state without claiming continuous custom byte progress.

Signed appcasts and full archives require Sparkle EdDSA validation. `SUVerifyUpdateBeforeExtraction`, `SURequireSignedFeed`, and a non-expiring signed-feed failure policy are enabled. Bounded notes are embedded in the signed appcast; external release-note downloads are disabled. The private key remains outside source control in operator-managed secure storage, and the corresponding public key is supplied through the local update configuration described in `Config/Updates.example.xcconfig`. The app embeds only the configured `SUPublicEDKey`. DSA, delta updates, source/deployment tokens, and private GitHub archive URLs are excluded. The eventual binary-only HTTPS host is separate from the private source repository and publishes immutable versioned notarized archives before atomically publishing the verified signed appcast last.

Install is a coordinated state transition. Active acquisition, briefing, scheduled, Vault, export, retention, migration, or Delete All work blocks readiness. The adapter postpones relaunch, stops admission, drains/cancels bounded work, saves and quiesces SwiftData, checkpoints and closes Vault SQLite, retains the mutation barrier, then invokes Sparkle's install handler exactly once. SwiftData and remaining in-process resources are finally released only when the old process really terminates for replacement; documentation or an in-process mock cannot prove that boundary. A failure before handoff leaves the current app in place and reports recovery truthfully. A successful replacement preserves the sandbox container and Keychain, then records a bounded version/build replacement/relaunch receipt after relaunch. Automatic downgrade/rollback is not promised; key loss or a bad build requires publication to stop and a separately reviewed signed/notarized higher build or approved non-destructive recovery release.

The authoritative detailed design contract is in
`docs/LOKI_BRIEF_P6U_SECURE_UPDATE_CONTRACT.md`. Internal live proof records and
recovery checkpoints are intentionally excluded from the public source
candidate. A future binary release must produce fresh, independently reviewed
signing, notarization, update, and clean-host evidence.

## P7/P8 Agent Loki Chat architecture

P8 retains one native app process and adds no helper, listener, browser-style
client, or background autonomous agent. Any installed local Ollama model may be
assigned to a compatible role, but only a current role-specific assessment may
make it effective. The application remains authority over context, routing,
attachments, tool requests, semantic evidence, research consent, receipts,
citations, persistence, and lifecycle admission. Deterministic briefs and
non-Chat surfaces remain independent of model-role readiness.

The closed tool registry covers current and historical briefs, bounded Vault search/item reads, connected-source and Slack selected-channel state, delivery status, update status, and an optional pure backfill preview. Tool execution is actor-owned, admission-controlled, cancellable, epoch-protected, and typed. Cancellation stops the client stream, prevents later tool execution, cancels pending reads, and rejects late success. Tool-using requests are never retried automatically.

The P7 SwiftData V8 layer stores only user-visible conversation state and
bounded disclosures; P8 V9 adds role assignments, privacy-safe routing and
reasoning receipts, migration state, and web-research controls. History
defaults on with 90-day retention; source excerpts default off; feed evidence
defaults on; selected Slack evidence defaults off per workspace and remains
distinct from scheduled-summary consent. Conversation deletion cascades
dependent Chat rows and invalidates any affected semantic generation. Delete
All closes admission; drains P8 lifecycle work; removes all Chat/role/research
state, the dedicated research credential, and the semantic database/WAL/SHM
family; and does not stop Ollama, delete installed models, or mutate external
providers.

Chat/model/tool work participates in P6U install readiness. New requests are rejected during preparation; active work is canceled or drained; truthful partial state is persisted; SwiftData and Vault quiesce through their existing barriers; and admission reopens only after an aborted install has restored required stores. Relaunch reconciles transient messages to `interrupted` and never accepts a completion from the previous epoch. See `docs/LOKI_BRIEF_UPDATE_RECOVERY.md`.

Detailed P7/P8 contracts are
`docs/AGENT_LOKI_CHAT_PRODUCT_CONTRACT.md`,
`docs/AGENT_LOKI_MODEL_CAPABILITIES.md`,
`docs/AGENT_LOKI_READ_ONLY_TOOLS.md`,
`docs/AGENT_LOKI_CHAT_PRIVACY.md`,
`docs/AGENT_LOKI_PROMPT_INJECTION_DEFENSE.md`, and
`docs/AGENT_LOKI_P8_MULTIMODAL_SEMANTIC_RESEARCH.md`.
