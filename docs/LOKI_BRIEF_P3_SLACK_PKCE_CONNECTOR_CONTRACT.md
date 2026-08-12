# Loki Brief P3 Slack PKCE selected-channel connector contract

Status: implementation and non-live verification complete. The repository seal is recovered through `agent-loki-v1-p3-slack-pkce-selected-channel-connector-gate`; external Slack application configuration remains pending and is not committed to this repository.

## Product boundary

P3 authorizes Slack as a read-only source for the current macOS user. It is not Sign in with Slack and does not create a Loki account. The connector uses only Slack user-token scopes, stays independent of the inherited TypeScript Discord runtime, and remains fully usable without Ollama.

The exact redirect is:

```text
com.agentloki.lokibrief://oauth/slack
```

This reverse-domain private-use scheme is the custom redirect form accepted by Slack's current PKCE manifest validator. The application registers only `com.agentloki.lokibrief` and separately validates the exact `oauth` host and `/slack` path, absence of user information/port/fragment, state, code or denial, attempt lifetime, cancellation state, and one-time consumption.

## Authorization and scopes

Slack OAuth uses `ASWebAuthenticationSession`, Authorization Code with PKCE, a 32-byte random verifier encoded as unpadded base64url, S256, and a separate one-time random state. The verifier and state exist only for the active attempt. Code and refresh exchange use `oauth.v2.access` with the public client ID and no client secret.

Required user scopes:

```text
channels:read
channels:history
groups:read
groups:history
users:read
```

Bot scopes, OpenID scopes, `users:read.email`, DM/group-DM scopes (`im:read`, `im:history`, `mpim:read`, `mpim:history`), `files:read`, `search:read`, `reactions:read`, `chat:write`, and every other write scope are excluded. Desktop redirects cannot request bot scopes under Slack's PKCE contract.

`auth.test` binds the returned credential to the authenticated workspace and user. Granted scopes and non-secret token freshness metadata are inspectable. A missing client ID produces `configurationRequired`; it never produces a connected placeholder.

## Credential boundary

One versioned credential envelope per Slack workspace/user belongs in an app-owned Generic Password record in the macOS Data Protection Keychain. The account key is derived only from non-secret team and user IDs. The record uses device-local post-first-unlock accessibility so a future separately authorized post-login helper could read it without making it synchronizable.

At the P3 seal, development verification used automatic Apple Development signing, an Xcode-managed Mac App Development provisioning profile, and the narrow application-derived Keychain access group. Those machine-local assets never enter Git. That evidence proved only the Debug Data Protection Keychain path; P6 now owns Developer ID release signing, release-profile reconciliation, hardened runtime, notarization, stapling, and packaging.

Access token, refresh token, authorization code, verifier, state, and Keychain payload never belong in SwiftData, UserDefaults, logs, traces, crash metadata, snapshots, fixtures, or UI. Initial create, read, atomic replacement, and delete have explicit reason-coded results. Refresh is serialized per workspace and atomically replaces the full validated envelope; a missing record never triggers silent credential recreation.

Rotating access tokens are refreshed before expiry with a bounded skew. Refresh tokens are one-use and may expire after 30 days for a PKCE-enabled Slack app. A refresh failure that needs human action transitions to `reauthorizationRequired` without opening a browser automatically.

## API and retrieval boundary

Only these operations are allowed:

```text
oauth.v2.access
auth.test
auth.revoke
conversations.list
conversations.history
users.info
chat.getPermalink
```

Every Web API call uses HTTPS to the fixed `slack.com` authority, rejects cross-authority redirects, places the token only in the `Authorization: Bearer` header, bounds response bytes and JSON depth, validates content type/status/top-level `ok` and the expected schema, and exposes a stable error reason rather than raw payloads.

Channel discovery requests only public and private channels, paginates by cursor, excludes archived channels, records membership truthfully, and defaults to no selection. At most 20 channels can be selected. Selection, enablement, channel weight, bounded display metadata, last refresh, and last failure are local non-secret state. Loki never joins, leaves, creates, or mutates a channel.

A manual refresh is sequential and selected-channel-only. Each channel receives at most one `conversations.history` page with `limit=15`. Retrieval uses a stored bounded lookback/window cursor, preserves partial success, supports cancellation, and never retrieves files, attachment bodies, linked pages, thread replies, edit history, or whole-workspace history.

The scheduler assumes Slack's restrictive non-Marketplace history class: one request per minute with 15 items. HTTP 429 and Slack `ratelimited` obey the exact `Retry-After` once and expose queued/waiting/rate-limited state. An idempotent transport/server failure may retry once; an expired access token may refresh once and replay once. Retry categories are ledgered so they cannot compose into an uncontrolled loop.

## Evidence and deterministic authority

Only bounded plain-text evidence is retained: workspace/channel attribution, privacy and membership classification, Slack timestamp identity, excerpt, bounded author display name/ID/classification, direct-mention state, reply/edit metadata, validated permalink, retrieval time, selected-channel weight, and provenance. Excerpts are capped; raw responses, emails, avatar data, files, attachments, canvases, reactions, hidden metadata, and thread bodies are discarded.

Slack mrkdwn is treated as untrusted text. Normalization recognizes the authenticated user's direct-mention token before stripping control syntax, never interprets HTML, never loads remote images, and never permits executable URL schemes. Identity is workspace + channel + message timestamp. Edits replace that identity deterministically; inaccessible or explicitly deleted evidence is tombstoned and purged within the bounded retention policy.

Slack evidence normally enters **Messages and Collaboration**. It enters **Needs Attention** only through documented deterministic inputs: direct mention, operator channel weight, bounded urgency keywords, and recency. Stable input produces stable ordering. Feed and Slack failures remain independent, and neither source erases the other's successful evidence.

Ollama never controls evidence inclusion, item identity, priority, selection, links, connection state, or read state. Existing feed-to-Ollama behavior is unchanged. Slack text may enter the fixed-loopback local provider only when that specific workspace has explicitly enabled **Allow local-model processing of selected Slack content**. Consent defaults off. Disabling it cancels affected generation, advances a generation epoch, and prevents late completion from restoring local-model text. No Slack content is sent to an external reasoning or control service, the TypeScript runtime, a cloud model, analytics, or telemetry.

## Persistence, deletion, and lifecycle

P3 is an additive SwiftData V3 schema with a lightweight V2-to-V3 migration. P1/P2 settings, feed sources/cursors/evidence, read state, brief history, Ollama selection/provider state, and generation provenance remain intact. Credentials remain exclusively in Keychain. A migration-open failure preserves the original store and uses the established truthful temporary fallback; it never resets the store.

Launch and relaunch perform no automatic authorization, discovery, sync, or browser work. Manual operations use a workspace epoch so authorization, refresh, sync, permalink, and local-generation results cannot land after cancel, disable, delete, disconnect, or whole-app deletion.

Disconnect is confirmed and local-first: cancel all Slack operations, invalidate late work, attempt bounded `auth.revoke`, delete the Keychain envelope, delete that workspace's selections/cursors/evidence/generated Slack presentation, preserve unrelated feed/Ollama/settings/history, and report remote-revocation uncertainty. Token revocation is not the same as uninstalling the Slack app; workspace removal remains an informational Slack-side action. Local deletion succeeds while Slack is offline.

## Observability and residual privacy risk

Slack trace events use timestamp, event, trace/span/parent IDs, component, allowed status, stable reason code, duration, and closed bounded metadata such as counts and redacted hashes. The production app writes deterministic bounded JSON events to the macOS unified log; Keychain create/read/replace/delete operations use only the operation name and a hashed account identifier. Events never contain token material, code/verifier/state, Keychain data, message excerpts, channel names, emails, prompts/model bodies, private URLs, or raw Slack errors.

Polling cannot discover every historical Slack deletion immediately, and one-page retrieval can leave a bounded backlog. P3 therefore uses bounded retention, truthful cursor/backlog state, immediate purge on confirmed deletion/access loss/disconnect, and documents that arbitrary historical deletion discovery requires a later separately authorized event or deeper polling architecture.

## Upstream contract references

- [Slack PKCE](https://docs.slack.dev/authentication/using-pkce/)
- [Slack token rotation](https://docs.slack.dev/authentication/using-token-rotation/)
- [Slack Web API rate limits](https://docs.slack.dev/apis/web-api/rate-limits/)
- [Slack conversations.history](https://docs.slack.dev/reference/methods/conversations.history/)
- [Slack app manifest reference](https://docs.slack.dev/reference/app-manifest/)
- [RFC 7636: PKCE](https://www.rfc-editor.org/rfc/rfc7636.html)
- [RFC 8252: OAuth for native apps](https://www.rfc-editor.org/rfc/rfc8252.html)
- [Apple ASWebAuthenticationSession](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession)
- [Apple Keychain services](https://developer.apple.com/documentation/security/keychain-services)

## Continuation boundary

P3 authorizes only the minimum Apple Development signing and provisioning required for the local Data Protection Keychain smoke. It does not authorize release signing, background scheduling, notifications, launch at login, helper execution, notarization, packaging, public distribution, DMs, posting, Events API, Socket Mode, webhooks, new native Discord ingestion, Google/social connectors, external reasoning or control execution, or P4 work.
