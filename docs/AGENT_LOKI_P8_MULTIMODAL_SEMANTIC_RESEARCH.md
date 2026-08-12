# Agent Loki P8 Multimodal, Semantic, and Research Contract

## Boundary

P8 is a local-first source foundation. It adds explicit model roles, private
reasoning transport, local image-file input, a rebuildable semantic index, an
opt-in Ollama web-research provider, and a normalized future-connector
ingestion envelope. It does not authorize model installation or deletion,
screen capture, audio/video input, computer use, connector authentication,
remote history pulls, external writes, or release activity.

Canonical user data remains in the existing SwiftData and Vault stores.
Embeddings and semantic chunks are derived, independently deletable artifacts.
P8 source verification must use disposable stores and repository-owned
synthetic fixtures; the production V8 store is not opened by this gate.

## Local model roles

The persisted roles are:

- `primaryAgent`
- `textFallback`
- `vision`
- `embedding`
- `briefSummary`

Every assignment records requested and effective identifiers, locality,
digest, assessment receipt and time, verified modalities/reasoning/tools/
structured-output/streaming, configured and effective context, readiness, and
a bounded unavailable or degraded reason. Discovery, recommendation,
selection, assessment, readiness, staleness, partial compatibility, and
unavailability remain distinct states.

Installed assessed `gemma4` is recommended for `primaryAgent` and `vision`.
Installed assessed `gpt-oss` is recommended for `textFallback` and may be
explicitly selected for `primaryAgent`. It remains text-only unless a future
receipt proves otherwise. `qwen3-embedding:0.6b` is recommended only for
`embedding` and is never used for Chat or pulled automatically.
`briefSummary` may inherit `primaryAgent` until explicitly overridden; an
explicit override is never silently reseeded.

Gemma 3 is absent from active defaults, recommendations, examples, and
model-specific policy. An active legacy Gemma 3 preference resolves only to an
assessed compatible Gemma 4, then an assessed compatible GPT-OSS, otherwise to
an unassigned assessment-required state. Historical receipts retain their
original model identifier. P8 never issues an Ollama model-delete operation.

No request silently switches models. An image-bearing request from a text-only
primary discloses the verified vision-role switch before submission. If no
ready vision role exists, submission is disabled with a reason. Routing
receipts contain role, model locality, reason, assessment, context, and
attachment presence but never prompts, record text, image bytes, file paths,
credentials, or reasoning.

## Reasoning transport

User modes are `Fast`, `Balanced`, and `Deep`. Assessed GPT-OSS maps them to
Ollama `low`, `medium`, and `high`. Other models expose only controls proven by
their receipt; a Boolean-only model presents a reduced truthful set.

Streaming decoding keeps `thinking`, visible `content`, and structured
`tool_calls` separate. Raw thinking may exist only as ephemeral state inside
the active turn and, when the Ollama protocol requires it, the immediately
continuing in-memory tool loop. It never enters Chat history, exports,
structured logs, semantic indexing, evidence, or final answer text and is
cleared on completion or cancellation. Persisted provenance is limited to
mode, model/assessment, duration and returned usage, tool-loop count, and
terminal status.

## Image-file input

P8 accepts explicit PNG, JPEG, and locally convertible HEIC/HEIF files through
picker, drag/drop, or clipboard-paste intake. Count, per-image bytes, combined
bytes, and decoded dimensions are bounded before model submission. The
model-bound representation strips metadata, has a local thumbnail and
accessibility label, supports removal and cancellation, and deletes protected
temporary conversion output after use.

Images use Ollama’s message `images` field only with a ready assessed vision
role. P8 does not request Screen Recording, Photos-library access, OCR,
microphone, audio, video, or computer-use permission. GPT-OSS is not treated as
vision-capable by name or estimate.

## Rebuildable semantic index

The semantic index uses system SQLite, FTS where available, stored numeric
vectors, and bounded in-process cosine reranking. Retrieval is:

1. deterministic normalization;
2. versioned deterministic chunking;
3. stable source and chunk hashes;
4. bounded lexical candidate retrieval;
5. embedding vectors;
6. bounded cosine reranking;
7. provenance-preserving assembly.

Each generation binds schema, embedding model identifier and digest, observed
dimension, chunker/normalization/source-schema versions, creation time,
high-water marks, and source hashes. Vectors from different generations are
never mixed. A changed model, digest, dimension, chunker, or normalizer marks
the generation stale and requires explicit rebuild.

Indexing is incremental, resumable, cancellable, deterministic, duplicate
suppressing, deletion/tombstone aware, and completely rebuildable. It exposes
health, freshness, progress, source/date filters, lexical/semantic/hybrid mode,
provenance, and similarity classification without exposing raw vectors. It
excludes credentials, keys, hidden reasoning, raw diagnostics, temporary and
recovery files, database sidecars, and deleted content after tombstone
processing.

The canonical source families eligible for semantic selection are current and
historical briefs, schedules, final completed user/assistant Chat messages,
selected Slack records only when both existing local-model and Chat-evidence
policies permit them, and Vault records only through an explicit
permission-filtered snapshot supplied by the Vault boundary. Eligibility is not
indexing authority. P8F requires a separate explicit build-source allowlist
before any corresponding adapter may run. The semantic layer has no generic
SwiftData/Vault query authority and never treats account connection, local
presence, a search filter, or connector eligibility as indexing consent.

P8 schedules no automatic or background indexing. Creation, replacement, and
rebuild are explicit foreground actions; a future scheduler would require a
separate policy and must remain off on battery unless separately authorized.
When the recommended embedding model is absent, explicit lexical-only rebuild
and search may remain available, while semantic and hybrid modes show the
truthful state:

> Embedding model required. Install qwen3-embedding:0.6b in Ollama, then reassess.

P8 never pulls the model and does not fail its source gate solely because the
model is absent.

## P8F semantic source authority

P8F keeps three authority planes separate:

1. **Index Build Source Authority** selects which canonical source adapters may
   be read for one explicit rebuild.
2. **Search Result Filters** narrow results already present in the active
   generation.
3. **Connector Ingestion Authority** would govern future provider
   authentication and remote ingestion and remains outside P8F.

No value crosses those planes implicitly. Search filters never authorize an
adapter, build-source selection never changes search filters, and connector
eligibility never grants indexing permission.

The stable closed semantic source-kind domain is `briefs`, `schedules`,
`chatFinalMessages`, `vaultRecords`, `slackRecords`, and `connectorRecords`.
Unknown, malformed, future, or unrecognized values fail closed. Provider-
specific connector records remain excluded until a later connector-authority
gate explicitly admits them.

Every manual rebuild request carries a nonempty `SemanticIndexBuildScope`
equivalent containing the source-authority contract version, canonical sorted
source allowlist, SHA-256 of that allowlist, request timestamp,
manual/operator-initiated classification, and a privacy-safe authorization
receipt identifier. Hashing is independent of UI ordering, stable for the same
set, different for different sets, and contains no source content or record
identifier. An empty or absent scope fails before any adapter is invoked; there
is no all-eligible-sources fallback.

Only selected adapters may be invoked. An excluded adapter receives zero calls
and performs zero record reads, previews, pre-counts, preparation, chunking, or
embedding work. In particular, excluding Slack or Vault means their adapters
are not opened even to compute a count. Each prepared record carries its stable
source kind and adapter authority evidence. The controller and derived-index
boundary validate both before normalization, chunking, embedding, persistence,
or publication. An unauthorized, unknown, missing, or adapter-mismatched source
kind rejects the complete build without persisting its text or publishing a
partial generation.

Every generation binds the source-authority contract version, exact canonical
allowlist and hash, and per-source adapter contract/version in addition to the
P8/P8E schema, model, full digest, Ollama runtime, embedding request profile,
dimension, chunker, normalizer, source schema, high-water marks, source hashes,
and creation time. A different build scope produces a different generation
identity. Incremental events may write only for sources in the active
generation’s bound allowlist; an excluded-source event performs no write.

Source-authority health distinguishes `sourceScopeReady`,
`sourceScopeUnknown`, `sourceScopeChanged`, `sourcePermissionRevoked`,
`sourceScopeViolation`, and `sourceScopeRebuildRequired`. A legacy generation
without an explicit source-authority identity is `sourceScopeUnknown`.
Unknown, changed, revoked, violated, or rebuild-required generations return no
lexical, semantic, or hybrid results; lexical fallback is not permitted when
unauthorized sources may be present. Their files remain preserved
non-destructively until an explicit rebuild or Delete All. Changing only a
search filter does not stale a generation.

The UI exposes two visibly independent sections:

- **Index Sources** governs only the next manual rebuild. First use selects no
  sources, Slack and Vault are off, the **Rebuild Selected Sources** action
  remains disabled until a nonempty explicit selection exists, and changing a
  checkbox never starts a rebuild.
- **Search Filters** narrows only the active generation. Selecting a source not
  present in that generation reports “not indexed” and never reads a provider
  or starts a rebuild.

Presentation distinguishes selected for next rebuild, present in the active
generation, enabled as a search filter, unavailable, and stale/rebuild
required. The next separately authorized live activation may select exactly
`briefs`, `schedules`, and `chatFinalMessages`; it must exclude `vaultRecords`,
`slackRecords`, and `connectorRecords`. That set is an operator selection for
the next activation, not a hard-coded permanent product policy.

Source-authority receipts use the stable event inventory:

- `semantic_rebuild_source_scope_requested`
- `semantic_rebuild_source_scope_authorized`
- `semantic_rebuild_empty_scope_rejected`
- `semantic_rebuild_source_adapter_invoked`
- `semantic_rebuild_source_adapter_skipped`
- `semantic_rebuild_source_record_prepared`
- `semantic_rebuild_source_scope_violation`
- `semantic_generation_source_scope_bound`
- `semantic_generation_source_scope_changed`
- `semantic_generation_source_permission_revoked`
- `semantic_generation_source_scope_unknown`
- `semantic_generation_source_scope_rebuild_required`
- `semantic_rebuild_source_authority_failed`
- `semantic_rebuild_source_authority_cancelled`
- `semantic_search_filter_narrowed`
- `semantic_search_filter_source_not_indexed`

Receipts contain only the runtime's privacy-safe fields: locally generated
event identifier; occurrence timestamp; event name; source-authority contract
version; source allowlist hash; the locally generated authorization receipt
identifier; the canonical stable source-kind list and optional stable per-event
source kind; optional adapter contract version; prepared-record, chunk,
indexed, excluded, tombstone, skipped, and rejected counts; optional generation
identifier; status; and reason code. The event identifier is scoped to one
event, the authorization receipt identifier is scoped to one rebuild, and
neither is derived from a user, record, provider, or content identifier. The
timestamp records only when the event occurred. Receipts never contain record
or message text, brief or schedule content, Slack or Vault content, remote
record identifiers, content-identifying raw hashes, vectors, credentials,
private filesystem paths, or hidden reasoning.

Rebuilds prepare a disposable generation outside the active generation and
publish only after every selected adapter completes, every record passes
authority validation, all chunking and embedding succeeds, counts reconcile,
identity is written, and cancellation/lifecycle epochs remain valid. Failure,
adapter error, authority violation, cancellation, or late completion preserves
the prior valid generation unchanged and disposes of or quarantines only the
incomplete candidate. Delete All removes active and incomplete generations,
source-authority metadata, and any persisted build-source selection required
by current product policy without touching canonical source data.

## Connector ingestion

`ConnectorRecordEnvelope` normalizes provider, pseudonymous account, remote
record and thread IDs, record type, source/ingestion timestamps, bounded text,
attachment metadata, deletion state, edit/version, source hash,
pagination/checkpoint receipt, provenance, and policy classification.
Deterministic reconciliation covers deduplication, replacement, tombstones,
pagination resumption, and semantic-index handoff.

The envelope is a P10 foundation only. P8 implements no provider login, OAuth,
API pagination, account-history pull, or backfill.

## Ollama web research

Web research is a provider separate from unauthenticated loopback Ollama. Its
only external authorities are:

- `POST https://ollama.com/api/web_search`
- `POST https://ollama.com/api/web_fetch`

The provider defaults off and requires explicit global enablement, a per-chat
toggle, first-use external-network disclosure, query preview, and a dedicated
Agent-Loki Keychain credential under its own service/account. The key never
enters UserDefaults, SwiftData, exports, logs, traces, or the semantic index,
and the provider never reads Ollama.app credentials. P8 source verification
uses a fake credential store and deterministic mock transport only; no live key
or endpoint is invoked.

Search results and fetched pages are untrusted evidence. URL policy permits
HTTPS only and rejects userinfo, unsupported schemes, localhost, IP-literal
bypasses, and private, loopback, link-local, multicast, and reserved
destinations. Result/fetch counts, redirects, response bytes, time, tool loops,
and context are bounded and cancellable. Private local records cannot
automatically become search queries; explicit operator action is required.

Research evidence preserves title, normalized source URL, retrieval timestamp,
tool receipt, bounded excerpt, and result-to-claim linkage. It cannot replace
system policy, change permissions, request credentials, authorize a connector,
trigger file/shell operations, or authorize another network call. Full
multi-step mode requires at least 64K effective context; lower capacity exposes
a limited-research state rather than silent truncation.

## Persistence and deletion

P8 uses additive `LokiBriefSchemaV9` for model-role and P8 control state while
retaining the ordered V1-through-V8 chain. Disposable migration tests must
prove V8 open, V9 migration, close/reopen, and idempotence. Semantic vectors
remain in the separate derived index rather than SwiftData.

Delete All closes P8 admission, advances the lifecycle epoch, cancels and
awaits attachment intake/consumption, semantic work, web-credential work, and
web dispatch, and rejects late results before deletion. It closes the semantic
store; removes the derived database plus its `-wal` and `-shm` family; clears
role/control state and research consent; and deletes the dedicated Agent Loki
Web Research Keychain envelope. It preserves external-provider data, installed
Ollama models, and recovery state; it does not claim to preserve credentials
that Delete All is explicitly required to remove. Partial cleanup remains
truthful and retriable.

## Source-gate proof boundary

P8 acceptance requires focused role, reasoning, vision, embedding/index,
connector, web-research, migration, lifecycle/privacy, and affected P7/P7R
regressions; the complete native suite; `git diff --check`; universal Debug and
Release builds with signing disabled; and the authorized loopback-only Gemma 4
and GPT-OSS synthetic matrices. A missing qwen3 embedding model is recorded as
an explicit live-probe skip while deterministic embedding/index proof remains
mandatory.

The durable P8 checkpoint records exact predecessor/Phase-0 identities, files
changed, V9 decision and migration, role/migration behavior, reasoning/vision/
embedding/web/connector proof, commands, counts, skips, durations, xcresults
and logs, limitations, intended staged paths, commit/tag/main identities, and
the final classification. Completion language is valid only after that evidence
exists and exactly one scoped commit, one annotated tag, and the local-main
fast-forward all resolve to the same P8 identity. No signed P8 installation,
live web credential, model pull, connector authentication/backfill, push,
release, or successor work belongs to this gate.

The successful final classification is:

`AGENT_LOKI_P8_MULTIMODAL_SEMANTIC_RESEARCH_READY_FOR_SIGNED_LIVE_GATE`

## P8E Qwen embedding-stability reconciliation

P8E supersedes the brittle live requirement that every repeated embedding
component remain within `1e-6`. Repeated
`qwen3-embedding:0.6b` requests can return slightly different component values
while retaining exact request/model identity, stable dimensions, finite
nonzero vectors, near-unit cosine, and unchanged retrieval ordering. The
accepted classification is therefore bounded backend numerical variance, not
vector determinism.

The live embedding assessment is serialized and uses canonical NFC/LF UTF-8
input, canonical request JSON, `truncate=false`, and the observed default
dimension both omitted and explicitly pinned. Readiness requires:

- exact model identifier and full digest;
- exact Ollama runtime and request-profile identity;
- one stable observed dimension;
- finite, nonzero vectors after the production `Float` conversion;
- minimum same-input cosine of `0.99999`;
- maximum relative L2-norm drift of `0.00001`;
- stable top-1 and identical ordered top-5 rankings over the separated
  repository fixture;
- no different-input collapse after the production `Float` conversion;
- equivalent single/batch rankings; and
- at least three repetitions inside an assessment.

The live gate invokes that complete assessment three independent times. That is
separate from the assessment's own `repetitionCount = 3`; neither requirement
may be replaced by one isolated pass. Component delta and RMS metrics remain
diagnostic evidence but are not durable model identity.

Semantic generation schema v2 binds model identifier, full digest, observed
dimension, Ollama runtime version, request-profile version and hash, dimensions
setting, truncate policy, normalization version, chunker version, source-schema
version, and source hashes. A safe atomic v1-to-v2 migration preserves derived
lexical/FTS/chunk/vector bytes. A legacy ready hybrid generation becomes
runtime-profile stale and permits lexical fallback only because its complete
lexical generation remains valid; building/paused/stale hybrid generations
become canonical-source stale and corrupt remains corrupt. A legacy ready
lexical-only generation remains ready, while other lexical states are
preserved and an unclassified stale state gains the canonical reason. Corrupt
or canonical-source-stale generations remain fail-closed, and partial
building/paused content never becomes a lexical fallback.

Fatal runtime dimension, non-finite, zero/collapse, response-model, or
request-profile evidence revokes the accepted embedding assessment, prevents
new semantic writes, and requires reassessment plus a new generation or
explicit rebuild. Service unavailability, timeout, cancellation, and HTTP
failure fail only the current operation and do not manufacture model
incompatibility. Production indexes are neither opened nor mutated by this
source-only reconciliation.

Privacy-safe product runtime and assessment receipts record fixture IDs, hashes,
request profile, dimensions, counts, durations, numerical bounds, ranking
hashes, state, and stable reason codes. They never record fixture text, raw
vectors, user text, production records, credentials, private paths, or hidden
reasoning. The separately authorized local gate receipt may record exact
temporary proof, log, and xcresult paths required for operator verification; it
is not emitted by the product runtime.
