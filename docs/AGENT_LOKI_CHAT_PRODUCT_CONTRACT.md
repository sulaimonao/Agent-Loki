# Agent Loki Chat Product Contract

## P8 boundary

Agent Loki is Loki Brief’s native, conversational analyst over evidence the user has already authorized. Ollama hosts local inference; Loki Brief owns presentation, authorization, bounded context, read-only tool execution, citations, local history, and lifecycle safety.

P8 remains read-only except for local conversation, model-role, attachment,
derived-index, and explicit research-control operations. It adds local
image-file input, semantic retrieval, and a disabled-by-default bounded Ollama
web-research provider. It does not add external reasoning, orchestration, or control authority,
external-account writes, arbitrary SQL, filesystem or shell access,
unrestricted fetching, background autonomy, journaling, goals/tasks, connector
login/backfill, or computer use.

The briefing, Vault, feeds, schedules, delivery, account, and secure-update features remain usable when Ollama is absent, stopped, degraded, or has no compatible assessed model.

## Native surfaces

The Today page may embed the compact **Ask Agent Loki** panel beside or below the current brief. The optional full **Chat** workspace provides:

- a paginated native conversation list;
- new, reopen, delete-one, and delete-all conversation actions;
- streamed user-visible assistant output;
- first-token, tool-request, tool-execution, completion, cancellation, failure, interrupted, and source-evidence-deleted states;
- explicit stop and user-initiated retry actions;
- copy and deterministic Markdown or JSON export;
- evidence, bounded read-only tool activity, and model/generation disclosures.

The composer placeholder is:

> Ask about this brief, your Vault, or connected sources…

Enabled local context scopes are **This Brief**, **Today**, **Vault**,
**Connected Sources**, and **History**. **Web** becomes available only after
the separate provider, disclosure, key, and per-chat controls are satisfied.
**Journal** and **Goals & Tasks** remain disabled planned states.

## Model gate

Any eligible installed model may be selected for a compatible explicit role.
Selection is not readiness: Agent Loki may send only when the role’s versioned
assessment matches provider, version, identifier, digest, and contract.

Primary, text fallback, vision, embedding, and brief-summary assignments are
independent. Brief summary may inherit primary only while unset. A text-only
primary visibly crosses to a ready vision role for an image request; otherwise
submission is disabled. No selection silently alters another explicit role.

Cloud model references are rejected before model inspection or chat transport. Fixed loopback alone is not treated as proof of local execution.

The Local Models surface presents:

- Primary, text fallback, vision, embedding, and brief-summary role cards;
- Semantic Vault Search — index mode, freshness, progress, filters,
  rebuild/cancel controls, and truthful missing/stale states;
- Images and screenshots — picker/drop/paste attachments, bounds, removal, and
  verified vision routing without screen capture;
- Web Research — disabled/key-required/limited/full states, disclosure, query
  preview, per-chat control, and evidence provenance.

## Evidence-bound answers

User-visible answer segments are classified as:

- **Observed** — directly supported by cited evidence;
- **Inferred** — local model interpretation of cited evidence;
- **Generated** — drafting or summarization that makes no factual source claim.

Factual Loki-data claims expose real evidence references. Unsupported answers say evidence is unavailable; the app never fabricates references.

The model may propose only a closed local read-only tool request or, when every
P8 research gate is satisfied, one separately schema-bound `web_search` or
`web_fetch` request matching the exact visible operator-approved preview. The
application validates tool name, argument schema, authorized account and
container scope, time and result bounds, cancellation state, current privacy
policy, and—only for research—the external-network disclosure, credential,
per-chat consent, preview, context, and URL policy before execution. Only
bounded receipts and evidence references cross into chat history.

External source text is untrusted evidence, never system or developer instruction. Source attempts to request tools, elevate authority, expose credentials, change memory, cause external action, or suppress citations do not gain authority.

## Conversation lifecycle

The additive V8/V9 store contains:

- conversations and user-visible user/assistant messages;
- selected context metadata;
- evidence references and optional bounded excerpts;
- bounded tool receipts;
- generation provenance;
- full bounded model-capability assessments and an explicit chat-model preference;
- explicit P8 model-role assignments and bounded P8 control state;
- chat privacy and per-workspace Slack-evidence policy.

Large Slack, feed, brief, and Vault bodies stay in their source stores.
Semantic chunks/vectors live in a separate rebuildable derived index. System
messages, tool messages, probe prompts, raw provider responses, hidden
reasoning, model thinking, image bytes, credentials, fetched pages, and
complete source bodies are not chat-history records.

Conversation pages are deterministic, newest first, with stable identifier tie-breaking. Reopening restores visible content and its bounded disclosures. On relaunch, pending, first-token, streaming, and tool states become a recoverable `interrupted` terminal state while preserving only truthful partial output.

Retention applies to inactive conversations and defaults to 90 days.
Delete-one cascades the conversation’s messages, context selections,
references, receipts, and provenance and must invalidate any derived semantic
generation that contains those messages. Delete-all performs the same cascade
for every conversation and likewise invalidates affected derived generations.
Delete All Local Data closes admission; cancels and drains Chat, model,
attachment, semantic-index, and research work; rejects late callbacks; removes
assessments, legacy and role selections, workspace policies, Chat settings,
research consent, the dedicated Web Research Keychain envelope, and the derived
semantic database plus its WAL/SHM family. It does not delete installed Ollama
models or external provider data.

Export is an explicit user action, limited to one conversation and bounded to 2 MiB. JSON and Markdown exports contain only user-visible messages plus bounded references, receipts, and provenance retained in the active ephemeral conversation or persisted local history.

## Accessibility

Controls carry specific labels and state. VoiceOver announcements occur at meaningful transitions such as question sent, generation started, completed, canceled, failed, or conversation deleted. Incremental token updates never create per-token announcements. Response text remains selectable, keyboard submission and cancellation are available, and destructive operations require confirmation in the native workspace.

## History, not memory

The user-visible disclosure is:

> Chat history is stored locally.
>
> Agent Loki does not create durable personal memories in this version.

P8 does not infer lasting preferences, extract durable memories, or offer
“Remember this.” The explicit rebuildable semantic index is derived retrieval
state, not durable personal memory. A future memory gate requires a separate
contract and explicit user approval.

## Stop condition

This P8 source contract is satisfied only when the role, reasoning, vision,
semantic-index, connector-envelope, web-research, V8-to-V9 migration, and
affected P7/P7R regression suites pass; the complete native suite passes;
universal Debug and Release builds succeed with signing disabled; the required
already-installed Gemma 4 and GPT-OSS loopback-only synthetic matrices pass;
and exactly one P8 commit, one annotated P8 tag, and the local-private-main
fast-forward read back to the same identity. A missing embedding model is an
explicit live-probe skip, not permission to weaken deterministic embedding and
index proof. Signed P8 installation, durable memory, journal, goals/tasks,
authenticated connectors/backfills, write actions, commercial work, and public
release remain separately authorized successor gates.
