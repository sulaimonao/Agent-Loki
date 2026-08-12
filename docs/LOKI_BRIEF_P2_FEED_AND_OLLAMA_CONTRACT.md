# Loki Brief P2 Feed and Ollama Contract

## Product boundary

P2 adds manually refreshed public HTTPS feeds and optional presentation-text generation through the separately installed Ollama application. Feed responses are attributable evidence. The deterministic engine alone selects, deduplicates, ranks, groups, and orders evidence. Ollama is never a connector, authorization authority, ranking engine, action engine, browser, or launch dependency.

## Supported feeds

- RSS 2.0, Atom 1.0, and JSON Feed 1.0/1.1 are detected from bounded response content and structure.
- Only the explicitly configured feed response is retrieved. Loki Brief does not fetch article pages, images, embeds, tracking resources, attachments, or browser sessions.
- Feed content is normalized to plain text. HTML markup is stripped; scripts, remote media, and executable markup are never rendered.
- Authenticated feeds, cookies, credentials, arbitrary headers, and plain HTTP feeds are excluded.

## URL and retrieval policy

Feed URLs must use HTTPS, contain no credentials, and resolve only to public addresses. The policy rejects local hostnames, loopback, link-local, multicast, unspecified, private-network, carrier-grade NAT, unique-local IPv6, IPv4-mapped private IPv6, alternate numeric host spellings, local paths, Unix sockets, the Ollama port, and every non-HTTPS scheme.

The same policy runs when a feed is saved, before every request, and for every redirect. Redirects are capped at five, HTTPS downgrade is rejected, and no sensitive header is forwarded. DNS resolution is injectable for deterministic tests and capped at 32 returned addresses. After all returned addresses pass the public-address policy, the client deterministically selects one approved address and opens a Network.framework connection to that typed numeric endpoint. TLS verification and SNI retain the original hostname, and HTTP/1.1 sends the original hostname in `Host`. The transport therefore performs no second hostname lookup between validation and connection. Every redirect is independently resolved, revalidated, and pinned before its request.

The pinned transport deliberately has no alternate-address failover during a single request. A multi-address host can therefore fail transiently when the selected approved address is unavailable. Requests explicitly advertise `Accept-Encoding: identity`; a server that nevertheless returns gzip or another content encoding is rejected before parsing rather than decompressed without a separate bounded-decompression gate. Address classification is conservative and fail-closed against the current IANA IPv4 and IPv6 special-purpose registries, including non-globally-reachable documentation, benchmarking, transition, and future-use ranges.

Central defaults:

- request timeout: 15 seconds;
- total resource timeout: 30 seconds;
- redirects: 5;
- response and parser input: 2 MiB;
- response headers: 64 KiB;
- feed URL: 4,096 characters;
- resolved DNS answers: 32;
- content encoding: identity only;
- concurrent refreshes: 4;
- retained entries per feed: 200;
- retained feed-entry period: 30 days;
- fetch records: 100 per feed;
- brief history: 365 days and 365 records;
- generation provenance: 365 records.

Limits are enforced before parsing or persistence. One absolute monotonic resource deadline spans DNS resolution, redirect validation, and every pinned transport hop; per-request timeouts cannot extend it. Cancellation is registered before DNS begins, returns the caller promptly during DNS, terminates prepared or active pinned connections, and discards any late resolver or transport result. The operating-system `getaddrinfo` call itself cannot be force-cancelled and may finish on its worker after the caller has already returned; its result is never accepted after cancellation or expiry. A failed refresh never deletes the last valid brief. The explicit “save as currently unavailable” path accepts only a policy-validated request that then encounters a network failure, request timeout, or unsuccessful HTTP status; DNS-policy and DNS-timeout, authentication, cancellation, size, encoding, parsing, and format failures are never retained as merely unavailable.

## Parsing safety

XML parsing uses in-memory bounded input. External entity resolution is explicitly disabled, external-entity policy is `never`, and DTD/entity declarations are rejected. Malformed, deeply nested, oversized, or unsupported input fails with a bounded reason code. JSON Feed requires a supported version, feed title, and item array; version 1 remains accepted through the JSON Feed 1.1 compatibility rule.

## Normalization and identity

Normalized entries retain source identity, title, summary, canonical item URL, author, publication/update/retrieval times, original position, format identifier, and upstream identifier. Missing titles and dates produce truthful bounded fallbacks.

Identity precedence is:

1. stable feed-provided identifier;
2. normalized canonical item URL;
3. SHA-256 of source identity, normalized title, and publication time;
4. SHA-256 of source identity, normalized title, and a bounded summary prefix.

Duplicates collapse within a response and across refreshes for the same subscription. Similar titles from different sources are not silently merged; corroborating source identifiers remain visible.

## Deterministic briefing

The engine receives normalized retained entries, enabled subscriptions, bounded settings, and an injected clock. Stable inputs produce the same brief identifier, item selection, order, priority, section placement, text, ranking explanation, and provenance.

Ranking uses explainable bounded signals: recency, topic preference, subscription weight, source type/category mapping, same-story corroboration, and read state. The fixed section order is Needs Attention, Messages and Collaboration, News and Research, and System and Product Updates. Explicit critical/urgent feed evidence may populate Needs Attention; most feed evidence populates News and Research or System and Product Updates. The engine never fabricates collaboration content.

## Manual refresh states

The native workflow exposes `idle`, `validating`, `fetching`, `parsing`, `normalizing`, `assembling`, `generatingLocally`, `complete`, `partial`, `cancelled`, and `failed`. Validation, retrieval, parsing, and normalization report awaited progress to the active operation; operation identifiers and epochs prevent a cancelled or superseded task from overwriting newer UI state. Refresh All uses bounded concurrency, removes each source from the active set as its result completes, records per-source results, supports cancellation and retry, and preserves already-completed source state and partial success. Repeated clicks cannot create concurrent duplicate refreshes or duplicate brief-history identifiers.

## Native Ollama boundary

The provider origin is fixed to numeric loopback at `http://127.0.0.1:11434/api`. It rejects custom, credential-bearing, redirected, LAN, public, HTTPS cloud, and `ollama.com` endpoints, and disables system proxy routing. Only these operations exist:

- `GET /api/version` for a bounded health/version check;
- `GET /api/tags` to list already-installed local models;
- `POST /api/generate` for one bounded structured summary;
- cancellation of the active native HTTP task.

There is no model pull, push, create, copy, delete, embed, cloud, web-search, tool-calling, lifecycle-management, or automatic retry path. Models are installed and managed in the Ollama application.

## Local generation

Generation begins only after deterministic assembly succeeds and the user explicitly enables Ollama, discovers models, and selects one of the discovered model identifiers. The request is non-streaming and supplies a versioned JSON Schema. Feed text is serialized as untrusted quoted evidence with explicit instructions that it cannot grant authority, alter the schema, trigger tools/network, or change application behavior.

The provider may return an overall summary and section summaries for known section and item identifiers. Validation rejects unknown identifiers, duplicate identifiers, unknown properties, invented URLs/actions/sections, missing fields, malformed JSON, or overlong text. Model output cannot change evidence selection, order, rank, priority, source metadata, links, read state, or connector state.

Generation defaults to 30 seconds within a user-bounded 5–120 second range, a 16-item/16 KiB prompt-evidence cap, and a 512 KiB response cap. HTTP-task cancellation is authoritative for the client; Ollama documents no separate REST cancellation endpoint, so server-side termination is best effort.

## Fallback and provenance

Loki Brief remains fully useful when Ollama is disabled, absent, stopped, has no models, loses the selected model, times out, returns invalid output, or is cancelled. The deterministic brief stays intact and the UI records a truthful fallback reason without repeated automatic connection attempts.

Every local-generation record stores provider kind, selected model, numeric-loopback classification, prompt-template version, output-schema version, generation time, deterministic brief ID, source item IDs, completion/fallback status, duration/token metrics when supplied, and validation result. Full prompts, feed payloads, model context buffers, thinking output, credentials, system paths, and private Discord content are neither logged nor persisted.

## Persistence and retention

P2 additively preserves the P1 SwiftData entities and encoded brief history. New subscription, fetch, normalized-entry, assembly, provider, model-selection, local-model, generation-provenance, and P2-settings records contain bounded metadata only. Existing settings and P1 briefs migrate without destructive reset; migration failure is shown truthfully and the original store is preserved.

Delete All Local Data removes every P1 and P2 record. A reopened historical brief uses its persisted evidence order and generation attribution and is never silently regenerated with a different model.

## Privacy and known limitations

The app uses the App Sandbox client-network entitlement only. It has no incoming-network entitlement, ATS arbitrary-load exception, WebView, browser automation, OAuth, Slack/native Discord/external-control execution, notification request, login helper, background scheduler, telemetry, signing, packaging, or release work in P2.

P2 supports public unauthenticated feeds only. Feed discovery from arbitrary web pages, full-article retrieval, background delivery, and cloud models remain unavailable. Public hostnames that resolve to globally reachable IPv6 addresses are supported, but IPv6-literal feed URLs fail closed during canonicalization. Ollama's bounded HTTP API does not reliably distinguish “not installed” from “installed but stopped,” so Loki Brief reports the service as unavailable/not running without inspecting application paths or attempting lifecycle control. Injected trace events intentionally omit payloads and URLs and do not carry their own wall-clock timestamp or a default production sink; durable feed-fetch and generation-provenance records retain the applicable attempt/completion and generation timestamps.
