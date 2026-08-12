# Agent Loki Read-Only Tool Contract

## Purpose

Agent Loki may ask the native app for bounded local facts. The model does not execute tools. The app decodes a proposed request, validates it against a closed schema, authorizes its exact local scope, executes an injected read-only façade, and returns a typed result with evidence receipts.

This contract adds no SQL, filesystem, shell, generic network, provider-write, delivery-write, or update-write surface.

P8 preserves this local registry unchanged. Its optional `web_search` and
`web_fetch` functions belong to a separate external-evidence provider and are
never aliases for a generic local/network tool.

## Closed Registry

Schema version: `agent-loki-read-only-tools-v1`

| Tool | Arguments | Maximum records |
| --- | --- | ---: |
| `get_current_brief` | none | 1 |
| `get_brief_by_id` | required `brief_id` string | 1 |
| `search_brief_history` | optional `query`, `start_at`, `end_at`, `limit` | 50 |
| `search_vault_text` | required `query`; optional `account_id`, `container_id`, `start_at`, `end_at`, `limit` | 20 |
| `get_vault_item` | required `item_id` string | 1 |
| `list_connected_sources` | optional `limit` | 50 |
| `get_source_health` | required `source_id` string | 1 |
| `list_slack_workspaces` | optional `limit` | 50 |
| `list_selected_slack_channels` | required `workspace_id`; optional `limit` | 50 |
| `get_delivery_status` | none | 1 |
| `get_update_status` | none | 1 |
| `preview_backfill_request` | required `workspace_id`; optional `channel_ids`, `item_limit` | 1 |

`preview_backfill_request` is a pure preview. Its adapter must return an explicit non-starting disposition and must never call the backfill starter.

Unknown top-level request fields, unknown tools, unknown arguments, duplicate array identifiers, empty identifiers or queries, invalid argument types, limits outside the declared cap, invalid date ordering, and date spans longer than 366 days are rejected before data access.

## P8 External Research Tools

The separate research schema exposes only:

| Tool | Arguments | Bound |
| --- | --- | ---: |
| `web_search` | required previewed `query`; optional `max_results` | 10 results |
| `web_fetch` | required normalized public HTTPS `url` | bounded fetch count |

Both require global provider enablement, a dedicated credential, first-use
external-network disclosure, and the current chat’s Web Research toggle.
Requests have bounded time, bytes, redirects, fetch/tool-loop counts, and
cancellation. URL validation rejects credentials, unsupported schemes,
localhost, IP-literal bypasses, and private, loopback, link-local, multicast,
or reserved addresses before dispatch.

Search/fetch results are untrusted evidence. The provider returns bounded
title, URL, retrieval time, excerpt, and receipt records; it never returns
authority to change policy or invoke another tool. Private Vault or connector
content requires an explicit operator-approved query and cannot trigger
research automatically.

## Execution Boundary

`AgentLokiReadOnlyToolDataSource` is the only application integration boundary. It deliberately exposes dedicated snapshot methods rather than a generic query or action method.

An application adapter must:

1. Read already-local application state.
2. Resolve the current brief from the newest persisted non-preview brief, not a history item selected for display.
3. Authorize brief, Vault item, Vault account/container, source, Slack workspace, and backfill-preview scopes against the current local allowlist.
4. Return bounded `AgentLokiToolSnapshot` values.
5. Never refresh a feed, call Slack, run an update check, trigger delivery, install an update, mutate a schedule, or start backfill.
6. Enter `beginVaultForegroundRead()` before every Vault search/item read and balance it with `endVaultForegroundRead()` on success, failure, and cancellation. The production adapter should bridge these calls to the existing Vault foreground-operation barrier so update readiness observes active reads.

Authorization is checked after structural validation and before any snapshot method. A denied account/container/workspace request does not enter the Vault barrier or read data.

## Lifecycle and Cancellation

`AgentLokiReadOnlyToolExecutor` is an actor with explicit admission and epoch state.

- `execute` validates, authorizes, registers a cancellable task, reads, bounds the snapshot, and emits a final receipt.
- `cancelAll` closes admission, advances the epoch, and cancels registered reads.
- Late results from a previous epoch are discarded as cancelled.
- `resume` advances the epoch again and reopens admission.
- `activeRequestCount` is available for the P6U update-readiness composition layer.

Delete All and update preparation must call `cancelAll` and await the application’s combined readiness barrier. The composition layer must not reopen admission until persistence/provider lifecycle work is complete.

## Evidence and Answer Claims

Stored content origin and answer epistemics are separate:

- `AgentLokiEvidenceContentOrigin`: source, generated, application state
- `AgentLokiClaimBasis`: observed, inferred, generated
- `AgentLokiEvidenceTrust`: authorized external untrusted, local generated, local application state

Each `AgentLokiEvidenceReference` retains:

- source kind;
- bounded account and container classification;
- source item identifier;
- source and retrieval timestamps;
- optional existing Vault identifier;
- bounded user-facing label;
- optional credential-free HTTPS direct-source action;
- content origin, trust classification, and claim basis.

Do not invent a Vault identifier or URL. HTTP URLs, credential-bearing URLs, malformed URLs, and fragments are not exposed as direct-source actions.

`StoredLokiToolReceipt` persists exactly `id`, `conversationID`, `messageID`, `requestIdentifier`, `toolName`, `status`, `reasonCode`, `requestedAt`, `completedAt`, `durationMilliseconds`, `resultCount`, `evidenceReferenceIDsData`, `argumentKeysData`, and `schemaVersion`. `requestIdentifier` receives the executor's canonical request hash. `argumentKeysData` encodes only the sorted key names from the validated request; argument values are never persisted. Executor-only truncation state is not a persisted receipt field. Receipts do not persist query text, source excerpts, result fields, account or channel names, URLs, or raw arguments.

The answer assembler may cite only the union of the current bounded-context allowlist and evidence IDs present in validated tool results. If authorized evidence is available but the model cites none of those IDs, the response is rejected as invalid structured output. If it cites at least one allowed ID, unsupported citation tokens are removed before display and persistence. An empty result is evidence of absence from the bounded authorized read, not permission to fabricate a citation.

## Privacy Defaults

- Feed evidence is enabled by default.
- Slack evidence is disabled per workspace by default.
- A Slack workspace must be both locally authorized for the tool request and explicitly enabled for chat evidence.
- Existing Slack-to-Ollama consent may be preserved by the application adapter, but it must not silently grant unrelated accounts or providers access.
- Display labels may be shown in the answer when authorized; they never enter traces.

## Trace Contract

The tool layer emits:

- `chat_tool_requested`
- `chat_tool_validated`
- `chat_tool_rejected`
- `chat_tool_completed`

Events contain trace/span/parent links, component, status, stable reason code, duration, registered tool name, hashed model identifier, evidence/result counts, token estimate when supplied, truncation, active request count, and schema version.

Events never contain prompts, request arguments, query text, source text, Slack/Vault contents, account/channel labels, identifiers, URLs, credentials, local paths, raw model output, or hidden reasoning.

## Verification

The isolated Role-B suite covers:

- exact closed registry and read-only descriptors;
- strict JSON and argument rejection;
- result/time bounds;
- account authorization before access;
- balanced Vault foreground barriers;
- cancellation, closed admission, and late-result invalidation;
- preview-only backfill;
- receipt/citation correspondence;
- trace linkage and content exclusion;
- deterministic context selection and source consent;
- hostile-source authority containment.

The P7 local-tool sources/tests and the separate P8 research-provider,
dispatch, URL-policy, credential, cancellation, and containment tests must
retain explicit Xcode project membership so the repository's normal
`xcodebuild test` lane continues to execute them.
