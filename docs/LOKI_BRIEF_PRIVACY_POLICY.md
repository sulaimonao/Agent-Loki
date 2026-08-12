# Loki Brief Privacy Policy

Historical detailed policy through the private P8F gate. It does not define
current source-release status. The public candidate policy and contact boundary
are [`PRIVACY.md`](../PRIVACY.md), [`SUPPORT.md`](../SUPPORT.md), and
[`SECURITY.md`](../SECURITY.md).

## Summary

Loki Brief is a local-first macOS application. It does not require a Loki cloud account, subscription, payment, license key, or receipt. Loki does not operate telemetry, analytics, advertising, user-data sale, cloud archive, or cloud-model fallback for Loki Brief. Agent Loki may assign any eligible installed local Ollama model to an explicit role, uses it only after a compatible role assessment, rejects cloud-model references before transport, and remains optional. Ollama Web Search and Web Fetch are separately disclosed external services and default off.

## Data stored on this Mac

- App settings, source metadata, delivery state, brief history, P7 chat control/history records, and P8 model-role/research-consent metadata use local SwiftData storage.
- Authorized feed and selected-channel evidence may be stored in the local Loki Vault SQLite archive.
- Bounded semantic chunks, vectors, lookup metadata, generation markers, and
  tombstones use a separate local derived SQLite index. The index is
  rebuildable, is not authoritative source content, and is created or replaced
  only by an explicit foreground action carrying a nonempty source allowlist.
  Each generation records the canonical source kinds selected for that build
  and a SHA-256 of the allowlist. Vault records require both the explicit
  permission-filtered semantic-search boundary and build selection.
- Slack access and refresh tokens use the macOS Data Protection Keychain and are not stored in SwiftData or Loki Vault.
- Chat history may store user-visible user/assistant text, context selection, bounded source references, optional bounded excerpts, read-only tool receipts, generation provenance, privacy/workspace policy, role-scoped model assessments and assignments, and explicit research-consent state.
- Complete Slack messages, feed bodies, briefs, Vault records, system/developer prompts, hidden reasoning, model thinking, image metadata, capability-probe prompts/output, raw provider payloads, semantic vectors, and credentials are not duplicated into chat history.
- Exports are created only at the user's request.

Vault content and `.lokivault` exports are not application-level encrypted. App Sandbox controls, current-user file permissions, restrictive archive permissions, and macOS disk protection provide the local boundary. FileVault is recommended. Exported files should be stored only in a trusted location.

## Network activity

- Feed requests begin at public HTTPS feed URLs explicitly saved by the user. Loki Brief may follow at most five HTTP redirects; every redirect target is independently revalidated against the same public-HTTPS and network-safety policy, so a policy-approved redirect host may differ from the originally saved host.
- Slack requests contact Slack OAuth and Web API services only after authorization and only for configured read-only operations.
- Ollama brief-summary, Agent Loki Chat, vision, and embedding requests use fixed numeric loopback on the same Mac. Loki Brief does not start or stop Ollama, install, pull, publish, delete, or reconfigure models, or contact cloud models.
- Ollama Web Search and Web Fetch, when separately enabled, contact only the disclosed HTTPS endpoints on `ollama.com`. They require both global and per-conversation consent, an outbound query preview, and an approved credential envelope. They never silently fall back from local model work.
- Enabled delivery schedules may perform the same bounded operations only while Loki Brief is running.

External providers process requests under their own policies. Loki Brief does not add a Loki-operated proxy or cloud service.

## Semantic index source choices

P8F separates **Index Sources** from **Search Filters**. Index Sources control
which canonical source adapters may be read for the next manual rebuild.
Search Filters only narrow results already present in the active generation;
they cannot authorize a provider read, add a source to the index, or start a
rebuild.

On first use, no Index Sources are selected and rebuild remains unavailable
until the user explicitly selects at least one source. Slack and Vault are off
by default. An excluded source adapter performs zero reads, including no
preview or pre-count. Selecting an unindexed source as a Search Filter reports
that the source is not indexed rather than reading the provider or rebuilding
automatically.

The next separately authorized live activation may select current and
historical briefs, schedules, and final completed user/assistant Chat messages.
It must exclude Slack, Vault, and connector records. This is an explicit
operator choice for that activation, not a permanent product default.
Connector authentication, remote pagination, and account-history backfill
remain outside P8F.

A generation without explicit source-authority metadata, or whose source scope
changed, was revoked, or was violated, returns no lexical, semantic, or hybrid
results. Its derived files remain local and preserved until explicit rebuild or
Delete All. A failed or canceled rebuild preserves the prior valid generation
and does not publish partial content.

## Slack and local models

Slack is an external read-only source, not a Loki login. Channel selection is explicit. DMs, files, posting, Events API, Socket Mode, webhooks, and workspace search are not used. Scheduled-summary consent and P7 chat evidence policy remain separate. Selected Slack evidence is off for Agent Loki Chat by default per workspace and enters chat context only when that workspace is authorized and explicitly enabled. Feed chat evidence defaults on and never grants Slack permission.

## Agent Loki Chat

The model does not receive direct access to SwiftData, Loki Vault, files, shell
commands, generic network requests, Slack, delivery, or updates. It may propose
only a registered read-only local tool or, after every independent P8 research
gate passes, one exact preview-bound `web_search` or `web_fetch` request. Loki
Brief validates the exact schema, account/container scope, result/time bounds,
current consent and authorization, cancellation, and—only for research—the
credential, disclosure, per-chat, preview, context, and public-HTTPS URL policy
before execution.

External source items are untrusted evidence. They remain separate from system policy and tool schemas, retain source attribution, and cannot authorize tools, credentials, memory changes, external actions, or citation suppression. Factual answers cite the bounded evidence returned for that request; when evidence is absent, Agent Loki says so.

P8 privacy defaults are:

- Store local chat history: on.
- Conversation retention: 90 days, with 30 days, one year, unlimited, and bounded custom alternatives.
- Include source excerpts in stored conversations: off.
- Allow feed evidence in Agent Loki Chat: on.
- Allow selected Slack evidence in Agent Loki Chat: off per workspace.
- Allow external web research globally: off.
- Allow external web research in each conversation: off.

Chat history and the derived semantic index are not durable personal memory. Agent Loki does not silently infer lasting preferences, extract memories, or provide “Remember this” in P8.

## Logs and diagnostics

Local structured logs use bounded event names, status values, reason codes, trace/span links, counts, classifications, registered tool names, and hashed identifiers. Semantic source-authority receipts may include the contract version, allowlist hash, stable source-kind names, generation identifier, and per-source prepared, chunked, indexed, skipped, or rejected counts. They must not contain credentials, tokens, user prompts, assistant responses, message bodies, channel names, private URLs, source bodies/excerpts, remote record identifiers, content-identifying raw hashes, vectors, tool arguments, raw model output, model thinking, exports, private filesystem paths, or hidden reasoning.

## Retention, export, and deletion

Users control source disconnection, account-scoped archive deletion,
conversation retention, one-conversation export, delete-one/delete-all
conversation actions, and Delete All Local Data. Deleting one conversation
cascades its messages, references, receipts, context, and provenance and
invalidates any affected derived semantic generation. Delete All Local Data
first closes admission, cancels and awaits model/tool/attachment/index/research
and credential work, and invalidates late callbacks. It then removes all Chat
history, settings, workspace Chat policy, role assessments and assignments,
research consent, active and incomplete semantic generations, source-authority
metadata, any persisted build-source selection required by current product
policy, the semantic-index database/WAL/SHM family, and approved credential
envelopes—including the dedicated Web Research key—in addition to predecessor
local data. It does not stop Ollama, delete installed models, open or delete
canonical source records, or delete external provider data. Existing data
remains readable, exportable, and deletable regardless of any future
entitlement state. Deleting the app bundle alone may leave local data and
Keychain items; follow the install/uninstall guide for complete removal.

## Contact and changes

Public usage and privacy questions use the repository routes in
[`SUPPORT.md`](../SUPPORT.md); vulnerabilities use the private route in
[`SECURITY.md`](../SECURITY.md). No support SLA or hardcoded private email
address is promised.
