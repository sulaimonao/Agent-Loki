# Loki Brief v0.1 Product Contract

Sections P4 and P5 below preserve historical milestone truth. The P6 Early Access addendum remains the Loki Brief 1.0.0 RC1 policy; the P7 addendum defines the current private Agent Loki Chat capability gate without authorizing distribution.

## Purpose and user

Loki Brief is the native, local-first macOS daily-brief surface within Agent Loki v1. It serves a single macOS user who wants a concise, attributable view of explicitly authorized information without requiring a Loki cloud account, an external reasoning or control service, Ollama, Discord, Slack, or any cloud service.

## Historical P4 core loop

At the P4 seal, the core loop launched from the Dock or menu bar, added an explicitly authorized public HTTPS feed and/or one or more Slack workspaces, selected accessible non-DM channels, manually refreshed current evidence, inspected the then-fail-closed entitlement state for bounded resumable historical backfill, searched the local Vault, and reviewed deterministic attributable briefings. P4 had no production entitlement provider, so new backfill Start/Resume was paused while existing ownership controls remained available; deterministic acquisition grants were test/preview-only. Slack defaulted to no selected channels. Historical imports did not become new merely because they were backfilled. Per-item provider, account, container, author, timestamps, provenance, and direct-source action remained inspectable. Preview fixtures were explicit and optional.

## Ownership and identity

- Application identity is the current macOS user. Loki cloud accounts and sync are unavailable.
- Brief history, settings, read state, account controls, policies, cursors, and job summaries are local SwiftData records. Authorized source history is stored separately in the local SQLite Vault.
- Feed authorization is the explicit user-managed subscription URL. Slack source authorization uses public-client PKCE and user read scopes; rotating credentials live only in macOS Keychain.
- Slack is an external source, not a Loki login. The current macOS user remains the application identity.
- Local model-provider connection is separate from sources and from any optional external authority.
- P7 conversation history, evidence references, tool receipts, generation
  provenance, Chat policy, and model assessments remain local SwiftData
  records. P8 adds model-role, privacy-safe routing/reasoning receipt, and
  research-consent state. Semantic chunks/vectors live in a separate
  rebuildable derived SQLite index; complete source bodies remain in their
  existing brief/feed/Slack/Vault stores.
- Users retain access to already stored data, export, disconnection, and
  deletion regardless of entitlement state. Delete All Local Data removes
  SwiftData, the Vault and semantic-index database/WAL/SHM families and staging,
  Slack credentials, and the dedicated Agent Loki Web Research Keychain
  envelope after closing admission and draining active work. Preview fixtures
  remain test-only and are not recreated by Delete All.

## Providers and authorities

The deterministic briefing engine is authoritative and remains available without a model. Ollama remains fixed numeric loopback and cannot alter source authorization, evidence selection, identity, rank, links, tools, or actions. Existing feed presentation consent is unchanged. Slack evidence has separate per-workspace local-model consent that defaults off and cancels affected in-flight work when disabled. P7 lets the user prefer any eligible installed local chat model, separately from the P2 brief-summary model; Chat remains disabled until bounded synthetic runtime assessment proves chat, streaming, structured output, tool calling, and cancellation. The model proposes tool requests; Loki Brief validates and executes registered local reads. No external reasoning or control service is connected or executed; the TypeScript Discord/Ollama runtime remains separate and unchanged.

## Privacy and unavailable functionality

At P4, networking was limited to explicit public HTTPS feed URLs, fixed-loopback Ollama, the Slack OAuth authorization page in the system browser, and allowlisted read-only Slack Web API methods. Vault stored bounded normalized selected-channel/feed evidence locally and never stored raw responses, files, thread bodies, tokens, verifier/state/code, prompts, or hidden reasoning. Archive content was not application-level encrypted; protection relied on the App Sandbox, restrictive file permissions, the macOS user account, optional FileVault, and Keychain isolation for credentials. DMs, posting, Events API, Socket Mode, webhooks, cloud accounts/models, background scheduling, notifications, launch at login, billing integration, telemetry, analytics, production non-Slack connectors, native Discord automation, and external reasoning or control execution were unavailable at that milestone.

## Release acceptance

P4 is accepted when the universal macOS Debug build and complete native suite pass; focused database/search/import/backfill/Slack-adapter/retention/export/entitlement/migration tests pass; P1-P3, feed/Ollama, Keychain, and inherited Node 22 regressions remain green; UI/runtime and privacy/secret/artifact checks pass; optional live Slack proof is reported truthfully; and only private `main` plus the annotated P4 tag are pushed. Missing external Slack application configuration yields a sealed-external-configuration-pending status, not fabricated history.

## P5 scheduled daily-use loop

P5 extends the P4 product without replacing it. One explicitly configured daily schedule runs only while the main menu-bar app is active. It claims one occurrence, performs bounded forward feed and selected-channel Slack synchronization, writes authorized evidence through Loki Vault, creates one authoritative deterministic brief, optionally applies separately consented local Ollama presentation, persists run/delivery history, and submits one privacy-aware local notification when authorized. Closing the main window does not quit the app; explicit Quit pauses schedules. Optional launch at login uses `SMAppService.mainApp`, never a helper process.

Missed-run reconciliation considers only the newest eligible occurrence and defaults to a six-hour grace window. Spring-forward resolves to the next valid time on the intended local date; fall-back executes the repeated slot no more than once. Notification permission is requested only through an explicit Delivery action. Default content exposes only a fixed title and bounded item/source counts. Production entitlement state remains truthful because P5 integrates no billing provider and does not hard-code a permanent commercial policy.

P5 acceptance requires recurrence, scheduler, orchestration, notification, login-item, V4-to-V6 migration including the historical pre-plan-metadata V5 shape, cancellation, late-result, interruption, privacy, and Delete All proof; P1-P4, Keychain, and Node 22 regressions; a strict development-signed universal build; literal live-smoke reporting; one private commit/tag/main seal; and no P6 work.

## P6 Loki Brief 1.0 Early Access addendum

Loki Brief 1.0.0 RC1 is a free early-access release candidate. Every currently implemented local feature is available without subscription, payment, Loki account, license key, receipt validation, StoreKit, Stripe, Paddle, licensing server, or cloud entitlement. Future paid features are not yet offered and no billing provider is configured. The provider-neutral entitlement boundary remains so a later release can make a separately authorized policy decision without restricting ownership of existing data.

Synthetic fixtures remain a test capability but are disabled and absent from shipping controls. Scheduling, notifications, Launch at Login, Slack local-model consent, and Ollama remain opt-in. Slack remains read-only and configuration-dependent. A P6 seal additionally requires the approved icon, consumer-safe release UI, Developer ID/profile/Keychain proof, universal archive, notarized/stapled/Gatekeeper-approved DMG, disposable clean-install/upgrade/uninstall proof, private Git seal, private draft release, and an entirely unchecked-to-approved prepublication boundary. No public distribution is authorized by this contract.

## P7/P8 Agent Loki Chat addendum

P7 adds **Agent Loki**, a native conversational analyst over information the
user has already authorized in Loki Brief. P8 extends it with explicit
primary/text-fallback/vision/embedding/brief-summary roles, private reasoning
transport, bounded local image-file intake, a rebuildable semantic index, and
disabled-by-default opt-in web research. Journal and Goals & Tasks remain
disabled planned states; Web is available only when its dedicated provider,
credential, disclosure, query preview, and per-chat control are satisfied.

Agent Loki is not an unrestricted autonomous agent and has no external control-plane authority.
P8 remains read-only except for local conversation, role, attachment,
derived-index, and research-control state plus explicitly approved external
research reads. The model has no direct database, filesystem, shell, generic
network, provider-write, delivery-write, update-write, or external-account
authority. A closed application registry exposes bounded local reads; a
separate provider exposes only exact preview-bound `web_search` and `web_fetch`
after its credential, disclosure, per-chat, context, URL, and lifecycle gates
pass. The application enforces exact schemas, account/container authorization,
result/time limits, consent, cancellation, and typed failures.

Every Loki-data factual claim is evidence-bound. **Observed** means directly supported by a retained reference, **Inferred** means local interpretation of cited observations, and **Generated** means drafting or summarization without a source-fact claim. External source text remains untrusted evidence in a separate bounded context layer and cannot become policy, tool schema, credential request, external action, memory instruction, citation suppression, or higher authority. Unsupported answers state that local evidence is unavailable.

Chat history is local and defaults on with 90-day retention. Source excerpts
default off, feed evidence defaults on, selected Slack evidence defaults off per
workspace, and Web Research defaults off globally and per conversation. Feed
consent grants neither Slack nor research consent. Chat persistence contains
user-visible user/assistant output, bounded references and receipts, generation
provenance, policy, capability assessments, role assignments, and bounded
research provenance; it excludes system/developer prompts, hidden reasoning,
model thinking, image bytes/paths, full fetched pages, raw provider payloads,
full Slack/feed/Vault bodies, and credentials. Delete All closes admission,
drains active lifecycle work, rejects late callbacks, removes Chat/role/research
state and the semantic database/WAL/SHM family, and deletes approved credential
envelopes without stopping Ollama or deleting installed models/external
provider data.

P8 semantic retrieval is an explicit rebuildable derived index; it does not
silently infer durable personal memory. The P8 connector envelope performs no
login, remote pull, or backfill. The remaining order is P9 Workbench,
P10 authenticated connectors/history pulls, P11 verified writes, and P12
commercial tier. Signed P8 installation, hosting, and release are separate.

P8 acceptance requires the complete native suite; focused role, reasoning,
vision, embedding/index, connector, research, migration, privacy, lifecycle,
and affected P7/P7R regressions; universal Debug and Release builds with signing
disabled; the required already-installed Gemma 4 and GPT-OSS loopback-only
synthetic matrices; privacy/secret/protected-artifact proof; and exactly one
private commit, one annotated tag, and local-main readback. An absent
`qwen3-embedding:0.6b` is recorded as an explicit live-probe skip and does not
weaken deterministic embedding/index proof. P8 does not authorize a signed
installation, production update host, application release, public
distribution, connector authentication/backfill, or successor work.
