# Agent Loki Model Capabilities

## P8 role capability gate

Agent Loki uses explicit `primaryAgent`, `textFallback`, `vision`, `embedding`,
and `briefSummary` roles. Any installed local model may be selected for a
compatible role after its role-specific assessment passes. Installation,
recommendation, selection, model names, and Ollama metadata remain discovery
signals rather than compatibility proof. An assignment is effective only while
its assessment matches provider, version, identifier, digest, and assessment
contract.

Assessed installed Gemma 4 is recommended for primary and vision; assessed
GPT-OSS is recommended for text fallback and may be explicitly primary.
`qwen3-embedding:0.6b` is recommended only for embeddings and is never
auto-pulled. Brief summary inherits primary only while unset; explicit
overrides remain independent. Active Gemma 3 preferences migrate to assessed
Gemma 4, then assessed GPT-OSS, otherwise unassigned. Historical receipts are
not rewritten.

## Capability levels

| Level | Capabilities | Effect |
| --- | --- | --- |
| Required | Role-specific: text Chat requires chat/streaming/structured output/tool calling/cancellation; vision also requires image input; embedding requires embedding-only proof. | Every capability required by the selected role must be proven before it becomes effective. |
| Recommended | System instructions, at least 64,000 best-known usable context tokens for full research, and model-specific reasoning controls. | Gaps remain visible and may produce a limited or partially compatible state. |
| Separate provider | Web research | Assessed text models may use it only when the external provider and per-chat control are explicitly enabled. |

Reliable multi-step tool use is exercised through the synthetic tool request and
tool-result continuation probes. It is not inferred from an Ollama capability
label.

## Profile, assessment, and preference

`ModelProfile` records bounded discovery metadata: provider and version, model
identifier and optional digest, local-install state, estimated Ollama
capabilities, and a declared context classification. Model names and estimated
capabilities never establish readiness.

`ModelCapabilityAssessment` is versioned as
`agent-loki.model-assessment.v2`. It records proven and missing capabilities,
assessment time and duration, the context policy, and bounded diagnostics with
stable reason codes. Raw probe prompts and outputs are not assessment records.

`ChatModelSelection` remains the backward-compatible P7 record.
`ModelRoleAssignment` is the P8 effective contract and records requested and
effective identifiers, locality, digest, assessment receipt/time, verified
modalities/reasoning/tools/structured output/streaming, context, readiness, and
bounded unavailable/degraded reason. The V9 migration preserves the legacy
storage contract for compatibility while deterministically creating role state
only from current assessed evidence; an active Gemma 3 value is replaced or
cleared according to migration policy, while historical result receipts are
never rewritten.

An assessment becomes stale when any of these change:

- provider;
- provider version;
- model identifier;
- model digest;
- assessment-contract version.

Absent evidence returns `assessmentRequired`; a changed assessment contract or
provider identity returns `staleAssessment`, and a changed digest returns
`staleDigest`. None silently keeps a model ready.

## Synthetic runtime assessment

The assessment uses synthetic content only and performs these bounded probes:

1. ordinary chat completion, including a system-instruction marker;
2. streamed output;
3. a response constrained by a small JSON schema;
4. exactly one synthetic, read-only tool request;
5. continuation after the application supplies a synthetic tool result;
6. authoritative client cancellation with no accepted late completion;
7. context-size declaration or a separately bounded empirical classification.

The application validates returned tool names against the request’s closed
allowlist and bounds tool-call count and JSON arguments. The model proposes a
call; it never executes one. Assessment does not read briefs, Slack messages,
Vault records, or other user evidence.

P8 augments that base Chat matrix with role-specific synthetic probes:
model-specific reasoning controls; repository-owned still-image input for a
candidate Vision role; and single, batch, repeated-input, and observed-dimension
embedding checks for a candidate Embedding role. A role becomes effective only
from the capabilities its current receipt actually proves.

Readiness states are `notInstalled`, `providerNotRunning`, `modelUnavailable`,
`assessmentRequired`, `assessing`, `ready`, `partiallyCompatible`,
`incompatible`, `degraded`, and `error`. Missing ordinary chat is incompatible;
another missing required capability is partially compatible. Provider or model
failure preserves a deterministic no-chat fallback.

## Native Ollama Chat boundary

`NativeOllamaChatProvider` permits only unauthenticated `POST` requests to:

- `http://127.0.0.1:11434/api/show`;
- `http://127.0.0.1:11434/api/chat`.

The transport rejects alternate hosts, hostnames, ports, schemes, credentials,
query strings, fragments, authentication challenges, redirects, cookies,
credential storage, proxy routing, and oversized requests or responses. It
does not start or stop Ollama, pull or delete models, change model
configuration, contact a cloud model, use Ollama web search, or retry
automatically.

The local-only boundary rejects any model identifier classified as a cloud
reference before `/api/show` or `/api/chat` transport begins. The current
classifier is deliberately fail-closed and may reject a locally named alias
containing `cloud`; this is preferred to silently offloading inference while
upstream exposes no stable locality field in the installed-model response.

Chat responses use bounded NDJSON decoding across arbitrary network
fragmentation. The provider decodes user-visible content, structured tool
calls, and Ollama `thinking` into separate channels. Thinking may be emitted
only to the active in-memory turn and carried through its immediately
continuing tool loop; it is never mixed into final content, logged, exported,
indexed, or persisted and is cleared at terminal completion. Response model
identifiers must match the effective model chosen by the explicit routing
receipt.

Cancellation closes the client stream with the stable
`ollama_chat_request_cancelled` reason and rejects a late terminal success.
Ollama exposes no separate REST cancellation endpoint, so server-side
termination remains best effort.

## Context policy

The profile extracts the text model’s declared context length from bounded
`/api/show` metadata while excluding vision and original-training context
fields. Classifications are `undeclared`, `below_recommended`, `recommended`,
and `extended`.

A declaration describes model metadata; it is not a long-context quality
claim. A bounded empirical receipt, when present, takes precedence. Input
budgets reserve output tokens. The provider sends `num_ctx`
only when the application explicitly supplies a validated
`configuredContextTokens` value; discovery never silently raises runtime
allocation.

## Trace and privacy contract

Production events use linked trace, span, and parent-span identifiers, a
component, status, stable reason code, optional bounded duration, and an
allowlisted metadata map. Relevant events cover runtime synchronization,
preference changes, model inspection and assessment, stream start, validated
model tool request, completion, cancellation, and failure.

Trace metadata contains only bounded counts, classifications, state, operation,
tool name, assessment version, and a SHA-256 model-identifier hash. It excludes
model identifiers in plaintext, prompts, response text, thinking, source
evidence, tool arguments, credentials, private URLs, and filesystem paths.

## Verification boundary

Fixture-backed tests cover role migration and independence, assessment
staleness, reasoning/content/tool separation, image bounds and metadata
stripping, embedding parsing and dynamic dimensions, semantic-index
generations, and opt-in research policy. They perform no live external-web
calls.

P8 live installed-model probes are separate from deterministic proof. When
present at Phase 0, `gemma4:12b` must prove chat, streaming, structured output,
model-specific reasoning, a synthetic read-only tool, repository-owned image
input, and context; `gpt-oss:20b` must prove chat, streaming, structured output,
low/medium/high reasoning, a synthetic read-only tool, text-only modality, and
context. `qwen3-embedding:0.6b` is probed only when already installed. Probes
must not start/stop Ollama, pull/delete models, use production content, or
contact a cloud endpoint.

## P8E embedding capability contract

An Embedding role is ready only when its persisted v2 model assessment carries
an accepted `agent-loki.embedding-stability-assessment.v1` summary for the
current model and runtime profile. Installation, model name, digest, dimension,
or one successful vector response is not sufficient.

The accepted summary binds:

- model identifier and full digest;
- Ollama version;
- `agent-loki.embedding-request-profile.v1` and its SHA-256;
- observed and explicit dimensions;
- `truncate=false`;
- `agent-loki.embedding-input.nfc-lf.v1`;
- request-identity and parser-parity proof;
- finite/nonzero/no-collapse outcomes;
- cosine, relative-norm-drift, norm, component-delta, and RMS bounds; and
- stable top-1, ordered top-5, minimum margin, and ranking hashes.

The conservative readiness floors are minimum cosine `0.99999`, maximum
relative L2-norm drift `0.00001`, at least three complete repetitions, stable
top-1, identical ordered top-5, and no different-input collapse in the exact
production `Float` ranking path. Exact component equality is deliberately not
a capability contract.

Runtime evidence invalidates an accepted summary only for recognized fatal
classes: response-parsing/association defect, dimension drift, non-finite
vectors, zero/different-input collapse, or runtime/request-profile identity
drift. The invalidation removes embedding capability proof, persists the
reassessment-required result, reconciles the Embedding role, blocks further
semantic writes, and emits the privacy-safe
`embedding_assessment_invalidated` event. Transient service, timeout,
cancellation, or HTTP failures preserve the accepted capability and fail only
the active operation.

Trace metadata for invalidation is allowlisted to hashed model identity,
assessment version, and state. Product runtime request and assessment evidence
may retain fixture identifiers, input/request hashes, dimensions, counts,
timings, metrics, and ranking hashes, but never raw input, vectors, prompts,
user or production text, credentials, private paths, or hidden reasoning. A
separately authorized local gate receipt may bind exact temporary proof/log/
xcresult paths for operator verification; it is not a product runtime receipt.

## P8F semantic source-authority binding

P8F does not change the P8E embedding assessment contract, numerical
thresholds, request-profile identity, model-role readiness, or runtime
invalidation rules. Embedding capability answers whether the selected local
model may create and query vectors; it does not authorize which canonical
source classes may be read.

A semantic generation is usable only when both identities are current:

- the accepted P8E embedding/runtime binding, when semantic or hybrid
  retrieval is requested; and
- the P8F source-authority binding containing the closed, canonical source
  allowlist and its SHA-256.

Build-source authority is independent from model roles and search filters.
Changing a search filter does not reassess a model or stale a generation.
Changing the build scope requires a new source-bound generation. A generation
with an absent, unknown, changed, revoked, or violated source scope returns no
lexical, semantic, or hybrid results, even when its embedding assessment
remains ready. This fail-closed source state must not revoke an otherwise valid
P8E embedding assessment.
