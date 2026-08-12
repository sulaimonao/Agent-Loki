# Agent Loki Chat Privacy

## Local-first data boundary

Agent Loki Chat lets the user prefer any eligible installed local Ollama model and uses it only after a current compatible assessment. Chat history is local SwiftData. Credentials remain in Keychain. The feature rejects cloud-model references before transport and does not grant the model direct database, filesystem, shell, network, or provider access.

The application—not the model—authorizes, validates, and executes the closed set of read-only local tools.

## Default controls

| Control | P8 default |
| --- | --- |
| Store local chat history | On |
| Conversation retention | 90 days |
| Include source excerpts in stored conversations | Off |
| Allow feed evidence in Agent Loki Chat | On |
| Allow selected Slack evidence in Agent Loki Chat | Off for every workspace |
| Ollama web-research provider | Off |
| Per-chat Web Research | Off |
| Store raw reasoning | Never |
| Semantic indexing | Explicit rebuild required |

Feed consent never implies Slack consent. Slack evidence requires the existing Slack-to-local-model consent path and the explicit P7 policy for the selected workspace. Turning excerpt storage off scrubs any previously stored bounded excerpts.

When local history is off, conversation, message, context, evidence, receipt,
and generation-provenance writes are no-ops. Capability assessments, role
assignments, research controls, and derived-index generation metadata remain
local operational configuration until Delete All Local Data removes them.

## P8 reasoning, image, semantic, and research privacy

Ollama `thinking` is decoded separately from visible content and structured
tool calls. It may exist only in the active in-memory turn and an immediately
continuing tool loop, then is cleared. History, exports, logs, accessibility,
and semantic indexing never receive raw thinking.

Selected images are decoded locally, bounded, stripped of metadata in the
model-bound representation, and sent only to the explicitly disclosed ready
vision role over fixed numeric loopback. File paths and image bytes are not
routing receipts or Chat history. Temporary conversion output is protected and
deleted after use. P8 requests no Screen Recording, Photos-library, OCR,
microphone, audio, or video permission.

The semantic index is derived and rebuildable. It contains deterministic
bounded chunks, hashes, vectors, and provenance, never canonical records,
credentials, hidden reasoning, raw logs, recovery files, or database sidecars.
It is rebuilt only through an explicit foreground action; P8 performs no
automatic or background indexing. Vault content enters only through an
explicit permission-filtered Vault snapshot, and selected Slack content
requires both the existing local-model consent and Chat-evidence policy.
Tombstones and source invalidation prevent deleted content from remaining
searchable in an accepted current generation.

External web research remains off until the operator configures a dedicated
Agent-Loki credential, enables the provider, acknowledges the external-network
disclosure, previews the query, and enables the current chat. Full fetched
pages are not normal history; only policy-bounded excerpts, URLs, retrieval
times, receipts, and claim links may be retained. Private local records never
become search queries automatically.

## What chat history may store

- conversation identifier, title, dates, selected context scope, and bounded target identifier;
- user messages and user-visible assistant responses only;
- visible Observed, Inferred, and Generated answer segments;
- source kind, authorized account/container classifications and identifiers, source item identifier, timestamps, local Vault identifier, bounded display label, and an already-supported HTTPS direct-source action;
- an optional excerpt of at most 500 characters, only when the user enables excerpt storage;
- bounded read-only tool receipts containing receipt, conversation, and message identifiers; registered tool name; opaque request identifier; status and reason code; request/completion timing; duration; result count; encoded evidence-reference identifiers; encoded sorted validated argument-key names; and schema version; argument values are never stored;
- bounded generation provenance containing provider/model identifier, assessment/template/schema versions, timing, token counts, evidence count, status, and reason code;
- bounded capability assessments and model-role assignments, including
  provider version and model digest needed to detect stale state;
- reasoning mode and bounded usage/status provenance, never reasoning text;
- bounded research evidence provenance when the user explicitly enables
  research.

## What chat history must not store

- system or developer prompts;
- hidden reasoning, chain of thought, model thinking, or internal scratchpads;
- raw Ollama requests or responses;
- image bytes, image file paths, or temporary conversion paths;
- capability-probe prompts or raw probe output;
- arbitrary tool arguments, SQL, filesystem paths, or network payloads;
- complete Slack messages, feed bodies, briefs, or Vault records;
- credentials, access or refresh tokens, private keys, cookies, or Keychain material;
- unrelated account data;
- silently inferred durable user preferences or memories.
- full fetched web pages or an Agent-Loki/Ollama API key.

Logs and accessibility announcements also exclude prompts, answer text, source text, Slack/Vault content, credentials, raw model output, and hidden reasoning.

## Retention, deletion, and source revocation

Retention choices are 30 days, 90 days, one year, unlimited, or a bounded
custom value. Retention pruning excludes an active conversation supplied by
the controller and deletes expired conversations with their dependent rows;
any derived semantic generation containing those messages must be invalidated.

Deleting one conversation removes its messages, context selections, evidence
references, tool receipts, and generation provenance and invalidates affected
derived semantic results. Deleting all conversations performs the same cascade
for every conversation while leaving model assessments and role assignments
intact.

Delete All Local Data must first close admission; cancel and await generation,
tools, attachment, semantic-index, web-credential, and web-dispatch work; and
invalidate late callbacks. It then removes all Chat data, privacy settings,
workspace policy, model assessments, legacy and role selections, research
consent, the dedicated Web Research Keychain envelope, and the semantic
database plus its WAL/SHM file family. It never deletes installed Ollama
models, stops Ollama, or deletes data from an external source.

P7’s explicit source-revocation flows—feed removal, Slack channel deselection, Slack consent/policy revocation, source/account disconnect, Vault retention/account deletion, and Vault/Delete All—remove dependent references, tool receipts, and provenance. An affected assistant message becomes a truthful source-evidence-deleted disclosure rather than retaining an unsupported answer. Provider-originated item-level tombstones are not a chat-history deletion control in P7; delete the conversation or revoke the containing source when that stored answer must also be removed. No supported deletion operation may recreate deleted data.

## Export

Export is explicit and limited to one selected conversation. Markdown and deterministic JSON contain user-visible user/assistant messages and the bounded evidence, tool, and generation records retained in the active ephemeral conversation or persisted for those messages. System/tool messages, hidden reasoning, raw provider payloads, and source bodies are excluded. Each export is capped at 2 MiB; the caller controls the final save location.

## Relaunch and update safety

After relaunch, nonterminal chat records are reconciled to `interrupted`. Truthful partial visible output may remain; late provider or tool callbacks cannot convert it to success. Before an update or Delete All Local Data, the shared controller must reject new requests, cancel generation and pending tools, drain or invalidate callbacks, persist a truthful terminal state, and cross the logical chat-persistence readiness boundary. SwiftData saves and quiesces at that boundary; physical release of its process-owned resources occurs only when the process terminates. Vault closes and reopens through its database lifecycle.

## User disclosure

The Today and full Chat surfaces state:

> Chat history is stored locally.
>
> Agent Loki does not create durable personal memories in this version.

Semantic retrieval is an explicit derived index, not inferred durable personal
memory. Journaling and goals/tasks remain outside P8. Web research remains
explicitly opt-in and off by default.
