# Agent Loki v1.0.0-rc.1 source release notes

Status: **locally verified, pending local seal**. The source implementation and
local acceptance gates passed. Exact commit, annotated-tag, local-`main`, and
artifact identities are recorded externally after sealing; none is claimed by
this pre-seal tree. No publication occurred.

## Shipped and locally verified

- Native local-first Loki Brief for attributable daily briefs.
- Public RSS, Atom, and JSON Feed sources.
- Read-only selected-channel Slack with PKCE and Keychain credentials.
- Local Loki Vault archive, search, retention, export, and provenance.
- Scheduled while-running local delivery and privacy-aware notifications.
- Agent Loki Chat over authorized local evidence with closed read-only tools.
- Optional role-assessed local Ollama generation, vision, and embeddings.
- Explicit semantic-index source authority, rebuildable derived storage, and
  fail-closed invalidation.
- The accepted private P8F baseline remains provenance; the changed source RC
  was independently exercised by the local verification described below.

## Connector release scope

- **Slack:** preserved native release feature.
- **Discord:** native read-only REST using an official bot identity, explicit
  guild/channel/thread selection, resumable bounded synchronization, and no
  Gateway or write endpoints. Its fixture and integration coverage passed.
- **Support Email:** credential-free, local `.eml` and `.mbox` import with
  bounded parsing, inert HTML handling, deterministic provenance/threading,
  restart-safe pagination, and late-parent thread repair. Its fixture and
  integration coverage passed.
- **IMAP and outbound email:** deferred.

Public licensing, community documentation, deterministic source packaging, and
fixture-only CI are present. CI is configured but has not run remotely.

The inherited root TypeScript Discord Gateway/moderation runtime remains a
separate write-capable program and is not the native macOS read-only REST
connector.

## Privacy

Canonical app data remains local. Credentials use Keychain or ignored local
configuration. Ordinary tests are synthetic and do not access live accounts.
There is no required cloud account, telemetry, analytics, crash upload, or
remote logging.

Optional external Ollama Web Research is separately disclosed and opt-in. It
does not silently run from private source content.

## Requirements

- deployment target macOS 14.0 or later for Loki Brief;
- locally verified release-preparation toolchain: macOS 26.6, Xcode 26.6
  (`17F113`), Swift 6.3.3;
- configured compatibility CI target: `macos-15` with Xcode 16.4, still
  `READY_TO_RUN`; and
- Node.js `>=22 <23`; Node 22.23.1 is the exact locally exercised runtime and
  CI selects Node 22. Node 26 is unsupported by the pinned native dependency
  graph.

## Local verification

- Complete native: 905 executed, 895 passed, 10 reviewed environment- or
  explicit-opt-in skips, 0 failed.
- Focused 28-class matrix: 415 executed, 412 passed, 3 reviewed skips, 0
  failed.
- XCTest inventory: 905 current methods versus 822 in the sealed baseline, 84
  additions, exactly one mapped semantic rename, and no other removal or
  duplicate.
- Universal unsigned Debug build-for-testing and default Release: passed for
  `arm64` and `x86_64`.
- Disposable application smoke: all 20 named selectors passed, with no skip or
  failure and successful task-owned cleanup.
- Node 22.23.1: 21 test files and 59 tests passed.
- Offline release verification and classification-only secret/history scans:
  passed without live credentials, provider accounts, production stores,
  remote Git operations, or publication.

GitHub fixture CI remains `READY_TO_RUN`; it has never run remotely and is not
represented as compatibility proof.

## Known limitations

- Optional live Slack and Discord account smokes were not run. Support Email V1
  has no live-account boundary; its required synthetic local-file smoke passed.
- Scheduling requires the main app to remain running.
- Ollama must be installed and configured separately.
- Vault and user-created exports are not application-level encrypted.
- Deleting the application bundle alone may leave local data and Keychain
  items.
- No signed binary, public update host, or automatic binary distribution is
  included in the source candidate.

## Source-release readiness

Current classification: `SOURCE_RC_LOCALLY_VERIFIED_PENDING_SEAL`. Fixture
suites, baseline-identifier reconciliation, universal builds, the complete
disposable application smoke, and supervisor review passed locally. The local
seal still must bind those results to the exact commit and annotated tag,
inspect the extracted source archive, generate checksums, record the identities
in the external verification packet, and fast-forward local `main`. The local
Apache-2.0 and project-artwork release decision is recorded; a final human
rights/notice confirmation remains a prepublication check rather than an
implementation blocker.

## Binary-distribution status

`BINARY_DISTRIBUTION_PENDING_SIGNING`. A source RC may be unsigned; no binary is
claimed until a separate signing, notarization, packaging, Gatekeeper, and
clean-install gate passes.

## Post-release roadmap

Maildir, read-only IMAP, attachment-body indexing, production connector
scheduling, Gateway acceleration, and a public update host remain separately
scoped roadmap work. The legacy root TypeScript Gateway/moderation runtime is
not a route to those native connector features.

## Verify the source

Verify the published checksum, extract into a new directory, and run
`scripts/verify-release.sh`. Publication must use the sanitized archive or a new
public repository initialized from it, never the private development history.
