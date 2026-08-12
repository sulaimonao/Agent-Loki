# Loki Brief Security and Data Handling

Historical detailed contract through the private P8F gate. It remains useful
architecture evidence but is not current source-release status. Public security
reporting is governed by [`SECURITY.md`](../SECURITY.md), and current candidate
findings are governed by [`SECURITY_REVIEW.md`](SECURITY_REVIEW.md). The prior
binary/update evidence does not authorize a production host or signed binary.

## Security boundary

Loki Brief is a sandboxed native macOS app with outgoing-network access and one app-specific Keychain access group. Direct distribution requires Developer ID Application signing, Hardened Runtime, secure timestamping, an app-specific Developer ID provisioning profile, Apple notarization, stapling, and Gatekeeper acceptance.

The production entitlement set is limited to:

- App Sandbox;
- outgoing network client;
- application and Team identifiers supplied by Apple signing;
- `$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)` as the sole Keychain group, resolved only by the current operator's Apple signing inputs;
- Sparkle installer communication through only `$(PRODUCT_BUNDLE_IDENTIFIER)-spks` and `$(PRODUCT_BUNDLE_IDENTIFIER)-spki` in `com.apple.security.temporary-exception.mach-lookup.global-name`.

P6U enables Sparkle's bundled Installer XPC service and does not enable its Downloader service because the host already has outgoing-network access. The release must not contain `get-task-allow`, unrelated temporary exceptions, Hardened Runtime/JIT exceptions, test injection, development provisioning, ad-hoc final signing, or unsigned nested code.

P8 adds no entitlement, helper process, incoming listener, browser view,
screen-recording/automation permission, remote-push capability, broad file
access, or new Keychain group. Its web key uses a distinct service/account
inside the existing application Keychain boundary.

## Update supply-chain boundary

Sparkle is pinned to the exact 2.9.4 Swift Package Manager binary product. A clean checkout embeds no update key and configures no update feed. A release operator who configures a feed must inject the matching base64-encoded 32-byte Ed25519 public key through ignored local or task-owned build configuration. Its private counterpart remains a sensitive generic-password item in that operator's login Keychain, separate from Loki Brief's Data Protection Keychain and application access group. The public repository records only the portable custody and recovery procedure—never either key value, an owner-specific key account or fingerprint, exported-key contents, or a user-private path.

Update archives require both Developer ID/notarization validation and Sparkle EdDSA signatures. Appcasts are signed and carry bounded embedded release-note descriptions; external release-note downloads are disabled. `SUVerifyUpdateBeforeExtraction` and `SURequireSignedFeed` are enabled, and signed-feed failure expiration is `0` so validation failure does not age into a reduced-information fallback. DSA and delta updates are prohibited in P6U.

The eventual update host is a separate token-free HTTPS binary host containing only signed appcasts, immutable versioned notarized full archives, checksums, and public manifest metadata. It has distinct channel routes, publishes verified archives before atomically replacing the signed appcast last, and contains no source, private GitHub release dependency, repository/deployment token, private signing key, Slack credential, or Loki account service. Key loss stops publication; recovery has no in-app path and requires a separately reviewed signed/notarized higher build or other explicitly authorized non-destructive release procedure. P6U uses only a disposable HTTPS host and publishes nothing.

## Data handling

- Credentials and rotating Slack tokens remain in the Data Protection
  Keychain. The Agent Loki Web Research key uses its own service/account in the
  same entitled boundary and never enters UserDefaults, SwiftData, exports,
  logs, or the semantic index.
- Control metadata, P7 conversation records, and P8 role/control state remain in SwiftData.
- Bounded normalized source evidence remains in Loki Vault SQLite.
- Semantic chunks and vectors remain in a separate rebuildable derived SQLite
  index. P8F creates/replaces it only through an explicit foreground action
  carrying a nonempty canonical source allowlist. Vault records require both
  the permission-filtered snapshot and explicit build selection; selected
  Slack records retain both local-model and Chat-evidence consent and also
  require explicit build selection. Excluded adapters perform zero reads.
- Chat history may contain user-visible user/assistant text, context selection, bounded evidence references and optional excerpts, read-only tool receipts, generation provenance, policy, and capability assessments. Complete Slack messages, feed bodies, briefs, and Vault records remain in their source stores.
- Raw API envelopes, image bytes/paths, full fetched pages, credentials,
  system/developer prompts, capability-probe prompts/output, raw model output,
  Ollama thinking, hidden reasoning, and arbitrary tool arguments are excluded
  from Chat persistence and logs.
- Vault and exports are not application-level encrypted; FileVault is recommended.

Delete All closes P8/P8F admission and drains model/tool, attachment,
semantic-index, web-credential, and web-dispatch work before deleting state. It
removes active and incomplete semantic generations, their source-authority
metadata, the semantic database and its WAL/SHM family, research consent, and
the dedicated Web Research Keychain envelope; partial cleanup is reported
truthfully. Installed Ollama models, canonical source stores,
external-provider data, and recovery state remain outside that deletion.

## Semantic source-authority boundary

P8F treats build authority, result filtering, and connector ingestion as
separate security planes. A search checkbox cannot authorize indexing. An
eligible or connected provider cannot authorize indexing. A selected build
source cannot silently alter search filters.

Every rebuild is manually initiated with a nonempty allowlist drawn from the
closed briefs, schedules, final Chat messages, Vault, Slack, and connector
source-kind domain. First use selects none; Slack and Vault default off.
Unknown or missing scope fails before adapter access. Only allowlisted adapters
may be invoked, and excluded adapters cannot read or count records. Every
prepared record is revalidated against the exact adapter and scope before text
normalization or persistence.

The complete generation is cryptographically bound to the allowlist and its
SHA-256. A legacy generation lacking that identity, or one whose scope is
changed, revoked, or violated, is preserved but cannot return lexical,
semantic, or hybrid results. Candidate generations publish atomically; an
adapter error, unauthorized record, cancellation, or late lifecycle completion
leaves the prior valid generation unchanged.

## Agent Loki Chat authority boundary

Agent Loki is a conversational analyst, not an unrestricted autonomous control
plane. Ollama hosts local inference and may propose a request;
Loki Brief owns model-role routing, reasoning privacy, attachment admission,
semantic retrieval, research consent, system policy, tool schemas, source
authorization, execution, citations, persistence, deletion, and lifecycle.

Only the exact closed local read-only registry and the separately gated
`web_search`/`web_fetch` schemas are accepted. The application rejects
unregistered tools, unknown arguments, raw SQL, filesystem/shell operations,
generic or unpreviewed URLs, provider writes, scope expansion, excessive
result/time bounds, unauthorized accounts or containers, consent bypass,
canceled requests, and attempts to turn reads into writes. Vault reads use the
existing foreground-operation barrier. The optional backfill tool is
preview-only and cannot start a job.

All external source text is untrusted evidence. It is bounded, attributed, consent-filtered, and encoded in an authority layer separate from policy, schemas, conversation, and the current user request. Tool-like or higher-authority instructions inside Slack, feed, brief, or Vault content remain inert. Answer citations are limited to evidence IDs returned by the current authorized read.

Chat history defaults on with 90-day retention. Stored source excerpts default
off. Feed evidence defaults on, selected Slack evidence defaults off, and feed
consent never grants Slack or research consent. The semantic index is derived
retrieval state, not silently inferred durable personal memory.

## Network and provider controls

Feed and Slack controls are unchanged. Local Ollama uses only numeric loopback
for bounded `/api/show`, `/api/chat`, and `/api/embed`; it cannot manage
models, invoke a cloud model, or silently switch roles. Ollama web research is
a separate fixed `https://ollama.com` provider that defaults off, requires a
dedicated key and explicit per-chat controls, and validates public HTTPS fetch
targets against userinfo, IP-literal, private, loopback, link-local, multicast,
reserved, redirect, size, time, and cancellation policy. Deterministic tests
use only mock transport and fake Keychain state.

## Operational evidence

Structured local events carry timestamps, stable event/status/reason fields, duration, and trace/span/parent relationships. Production events use summarized metadata and hashed identifiers. Safe diagnostics may include app version/build, selected channel class, macOS version, event name, status, reason code, timestamp, registered tool name, hashed model identifier, bounded token/evidence/result counts, source-authority version, source allowlist hash, stable source-kind names, per-source prepared/chunked/indexed/skipped/rejected counts, the download-start/validated-100-percent boundary, and redacted counts. These traces are authoritative for check/feed/archive/install/relaunch and bounded chat/model/tool/index state; receipts contain only the minimum disclosed outcome. Transport errors map to implemented stable categories rather than promising distinct DNS/TLS/HTTP/malformed-feed types. Diagnostics never include key material, signature bytes, appcast or release-note bodies, archive paths, credential-bearing/private URLs, prompts, user/assistant text, evidence excerpts, Slack or Vault content, remote record identifiers, content-identifying raw hashes, vectors, tool arguments, raw model output, hidden reasoning, database rows, or user-private paths. Do not share logs containing private content without review.

The private P6U live proof exercised signed HTTPS discovery, hostile channel/version/signature/archive paths, Developer ID/notarization validation, store close, replacement, and relaunch. Unified logs showed linked signature-validation, readiness with zero blockers, install-handoff, and relaunch events without exposing private payloads. The disposable preservation test verified SwiftData, Vault, Data Protection Keychain, schedules, history, and local-date state before fixture cleanup; operator app/data were restored, the held production area remained mode `0500`, and the ephemeral HTTPS trust/server were removed. This evidence does not authorize a production host, artifact, or release.

## Security reporting

The public source repository uses GitHub private vulnerability reporting as
described in [`SECURITY.md`](../SECURITY.md). If that feature is unavailable, a
minimal public issue may request a private route but must contain no
vulnerability detail. No response SLA is promised.
