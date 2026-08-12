# Loki Brief P6U Secure Self-Update Contract

Status: implemented and verified as a private foundation gate. The signed disposable HTTPS replacement/relaunch ladder passed on 2026-07-20; the prescribed private commit/tag are the only authorized seal. This is not a production update service or release authorization.

## Gate authority and release state

P6R is sealed at `agent-loki-v1-p6r-local-date-product-scope-checkpoint`. It corrected user-facing local-calendar dates and left P6 paused. The earlier notarized RC artifact remains superseded private engineering evidence and must not be published, installed as the public baseline, or reused as P6U proof.

P6U is one bounded continuation that establishes secure self-update foundations for an eventual public Loki Brief baseline. It does not resume the final P6 release, create a production appcast, publish an update archive, create a GitHub release, expose the private source repository, or authorize Agent Loki Chat or any other successor feature.

The P6U seal is one private commit named `feat(v1): establish secure in-app update foundation` and one annotated private tag named `agent-loki-v1-p6u-secure-self-update-foundation`. Only private `main` and that tag may be pushed. Neither is a public release.

## Upstream dependency and sandbox architecture

P6U pins the current stable Sparkle 2 release as of 2026-07-20:

- package URL: `https://github.com/sparkle-project/Sparkle`;
- exact version: `2.9.4`;
- package product and module: `Sparkle`;
- integration: Swift Package Manager binary product, with no source fork or vendored framework.

Sparkle's binary framework contains its supported XPC services. Loki Brief already has App Sandbox and outgoing network-client access, so P6U uses this exact service boundary:

- enable bundled `Installer.xpc` with `SUEnableInstallerLauncherService = YES`;
- add only Sparkle's required sandbox mach-lookup names, `$(PRODUCT_BUNDLE_IDENTIFIER)-spks` and `$(PRODUCT_BUNDLE_IDENTIFIER)-spki`;
- leave `SUEnableDownloaderService = NO` because the host already has `com.apple.security.network.client`;
- do not embed or enable `Downloader.xpc`, Installer Connection, or Installer Status services separately;
- retain Developer ID Application signing, Hardened Runtime, secure timestamping, the app-specific distribution profile, Data Protection Keychain behavior, and the sole application-derived Keychain group;
- verify the exported app and every Sparkle nested executable/service with the final distribution signature. `Code Sign on Copy` alone is not release proof.

No app-owned updater daemon, LaunchAgent, login-item helper, incoming listener, remote-push entitlement, broad ATS exception, or Loki cloud account is introduced. Sparkle's bundled installer service is the only new executable boundary authorized by P6U.

## Provider-neutral update domain

Sparkle is an adapter behind a provider-neutral update domain. Product and persistence code must not depend directly on Sparkle-specific states.

- `UpdateChannel`: `stable`, `beta`, or `internal`; persisted default is `stable`. Stable accepts only stable candidates; an explicitly selected beta or internal channel accepts its own candidates plus stable candidates.
- `UpdateState`: `idle`, `checking`, `updateAvailable`, `downloading`, `readyToInstall`, `installBlocked`, `installing`, `relaunching`, `upToDate`, `offline`, `feedUnavailable`, `failed`, `installed`, or `recovered`.
- `UpdateAvailability`: one bounded candidate value containing channel, marketing version, machine build, embedded release-note text, publication date, and optional content length.
- `UpdatePolicy`: selected channel, automatic-check opt-in, signed-feed requirement, signed-archive requirement, and full-archive-only policy.
- `UpdateCheckResult`: check time, selected channel, and one outcome: no update, available, offline, feed unavailable, or rejected with `UpdateFailure`.
- `UpdateInstallReadiness`: a deterministic list of active feed, Slack, Vault database, local-generation, SwiftData, delivery, Delete All, or store-close blockers; an empty list is ready.
- `UpdateFailure`: one implemented stable code, a recoverability flag, and a bounded consumer-safe message. Codes cover offline/feed unavailable, invalid feed or archive URL, unsigned feed or archive, invalid/prohibited signature, prohibited delta, disabled automatic check, older build, wrong channel, incompatible system, download failure, installation block, store-close failure, relaunch failure, provider failure, and invalid transition.
- `UpdateReceipt`: a bounded replacement/relaunch outcome containing receipt ID, channel, previous and resulting version/build, `installed`/`recovered`/`failed` status, start/completion times, and reason code. It does not claim to contain check, feed, archive, or signature-validation evidence.

State transitions and privacy-safe traces are authoritative for check, feed resolution and signed-feed acceptance, archive validation, install handoff, relaunch, and post-relaunch validation. `UpdateReceipt` is only the bounded cross-launch replacement/relaunch outcome. Transport failures may map into the implemented stable `offline`, `feed_unavailable`, `invalid_signature`, `download_failed`, or `provider_failure` categories; P6U does not promise separate persisted DNS, TLS, HTTP-status, and malformed-feed failure types. A failed check must not be represented as "up to date."

## Channels and feed resolution

Stable is the default and fail-closed channel:

- stable items use Sparkle's default channel and stable builds return no additional allowed channels;
- beta items use `sparkle:channel` value `beta`;
- internal items use `sparkle:channel` value `internal`;
- Sparkle always includes its default channel, so beta/internal operators may also receive a newer stable build;
- a stable build cannot consume beta or internal items unless the operator explicitly changes the selected channel;
- channel changes are explicit user/operator actions, persist locally, reset the update cycle through Sparkle's supported API, and are recorded without logging feed URLs.

Each channel key is declared in checked-in non-secret configuration and resolves at build time to a token-free HTTPS appcast route. P6U leaves production values uncommitted. Dynamic selection uses the updater delegate's supported feed-resolution API rather than the deprecated persisted `feedURL` setter. No source-repository token, private GitHub release URL, credential-bearing URL, or environment-file secret is compiled into Loki Brief.

The eventual public update host is a repository and deployment surface separate from the private source repository. It is binary-only and contains only the applicable channel's:

- `appcast.xml`;
- notarized full update archives;
- bounded release-note descriptions embedded in the signed appcast;
- public checksums and non-secret manifest metadata.

External release-note URL downloads are disabled for P6U. Ordinary users must never depend on authenticated private GitHub release URLs. P6U may use only a local HTTPS server or repository-approved disposable host for verification; it does not publish the production host.

## Check and installation policy

Automatic checking is opt-in. The initial configuration is explicit:

- `SUEnableAutomaticChecks = NO`;
- `SUAllowsAutomaticUpdates = NO`;
- `SUAutomaticallyUpdate = NO`;
- no update or installation permission prompt at first launch;
- no silent automatic download, install, or relaunch;
- the automatic-check preference changes Sparkle's persisted `automaticallyChecksForUpdates` value only in response to an explicit user action;
- `Check for Updates…` remains available for a manual check when `canCheckForUpdates` is true.

Loki Brief settings report current marketing version/build, selected channel, automatic-check preference, provider-neutral state, availability, bounded embedded notes, and install-readiness truth. Sparkle's standard update window owns the live download, approval, install, and relaunch interaction. Loki Brief traces the download-start and validated 100-percent boundary and reflects that bounded boundary in provider-neutral state; it does not claim a custom continuous-byte user driver. Privacy-safe traces—not the receipt—are authoritative for the check/feed/archive/install/relaunch validation path.

## EdDSA and signed-feed custody

P6U uses Sparkle EdDSA/Ed25519 only. DSA keys and `sparkle:dsaSignature` are prohibited.

Each release operator generates or adopts a controlled key pair with Sparkle 2.9.4's supported `generate_keys` tool. The clean source tree commits neither key and expands `SUPublicEDKey` to an empty owner-neutral build setting. Configuring any update feed requires injecting the matching base64-encoded 32-byte Ed25519 public key through ignored local or task-owned build configuration. The private key is never placed in the app, source tree, Git history, shell environment files, xcconfig files, CI logs, app logs, screenshots, support bundles, chat, or the binary-only update host.

The non-secret custody metadata is:

- owner: release operator;
- host class: operator-managed release Mac;
- store: that operator's login Keychain, separate from Loki Brief's runtime Data Protection Keychain and app-specific access group;
- item class: sensitive generic password created by Sparkle;
- service: `https://sparkle-project.org`;
- label: `Private key for signing Sparkle updates`;
- account: operator-selected and retained outside the public repository;
- generation/rotation record: retained in the private release packet;
- public-key fingerprint: verified in the private release packet, never committed as an owner identifier;
- repository record: portable custody and recovery procedure only, never either key value or an exported-key path containing user-private directory information.

Every update archive carries a Sparkle EdDSA signature in addition to Developer ID signing and notarization. The appcast is signed and carries bounded embedded release-note descriptions; P6U does not fetch external release-note documents. Loki Brief enables:

- `SUVerifyUpdateBeforeExtraction = YES`;
- `SURequireSignedFeed = YES`;
- `SUSignedFeedFailureExpirationInterval = 0` so signed-feed failures never expire into a reduced-validation path.

Key loss has no in-app recovery path. Stop publication if custody is lost. Recovery requires a separately reviewed Developer ID signed and notarized higher build or other explicitly authorized non-destructive release path that can establish new trusted update configuration; P6U does not authorize ad hoc key rotation. That limitation must remain visible in the release and support documentation.

## Full-update-only publication pipeline

P6U establishes full archives before any delta policy exists. `generate_appcast` must be invoked with `--maximum-deltas 0` in a fresh disposable archive directory. Verification must prove there are no `.delta` files and no delta entries in the generated appcast.

The future production sequence is:

`source change -> tests -> version increment -> Developer ID build -> notarization/stapling -> immutable versioned full archive -> Sparkle EdDSA archive signature -> candidate manifest verification -> archive publication -> signed appcast generation/verification -> atomic appcast publication last -> user in-app update`

The binary host uses immutable versioned archive names and distinct stable/beta/internal routes. Operator deployment credentials remain outside the app, repository, appcast, URLs, and logs. Publication must verify the archive and appcast before changing the channel route, and the signed appcast is the last atomically replaced object so it never advertises an unavailable archive.

The appcast machine version is the monotonically increasing `CFBundleVersion`; `CFBundleShortVersionString` is display-only. A downgrade or same-build item is rejected. Delta generation remains a future, separately authorized gate after at least two compatible public baselines exist.

## Install readiness and data preservation

Sparkle may replace the app bundle only after Loki Brief reports install readiness. Active feed/Slack refresh, scheduled delivery, briefing generation, Vault work, export, retention, migration, or Delete All work blocks installation with a truthful reason.

When the user chooses Install and Relaunch:

1. stop admitting new work;
2. wait for or cancel bounded active work using the existing generation/epoch fences;
3. save and quiesce SwiftData, checkpoint and close Loki Vault SQLite connections, and retain the mutation barrier;
4. verify no persistence transaction or destructive operation is active;
5. invoke Sparkle's postponed-install handler exactly once;
6. let real process termination release the SwiftData container and remaining in-process resources before app-bundle replacement;
7. after relaunch, confirm the expected version/build and record a bounded receipt.

If Delete All begins first, installation remains blocked until deletion completes. If install shutdown has begun first, Delete All is unavailable with an explicit reason rather than racing closed stores. A readiness timeout or store-close failure leaves the current app installed, exposes recovery guidance, and does not claim rollback succeeded.

The app bundle is separate from the sandbox container and Keychain. A successful update must preserve Vault data, feed and Slack account metadata, Keychain credentials, schedules, brief history, local-calendar behavior, settings, and receipts. P6U verification may use isolated disposable state under the same macOS user when its paths are explicitly bounded and journaled. It must keep the held production state untouched, restore the pre-proof app/data state, and never open, reset, migrate, delete, or substitute production data as a fixture.

Sparkle prevents ordinary downgrades; P6U does not promise automatic rollback. Recovery from a bad installed build requires a separately signed/notarized higher-build recovery release or an explicitly approved reinstall that preserves the sandbox container and Keychain. Support must never prescribe Delete All or destructive container cleanup as an update repair shortcut.

## Privacy-safe update observability

Update events form a traversable local trace with `ts`, `event`, `trace_id`, `span_id`, `parent_span_id`, `component`, `status`, `reason_code`, `duration_ms`, and bounded `metadata`. Allowed statuses remain `started`, `success`, `degraded`, `failed`, and `skipped`.

Stable event families cover check intake, policy/channel selection, feed resolution and validation, availability selection, the download-start/100-percent validation boundary, archive validation, install readiness, store preparation, install handoff, relaunch request, post-relaunch confirmation, receipt recording, cancellation, and recovery. Stable reasons distinguish manual check, automatic checks disabled, offline, feed unavailable, signature/archive rejection, channel disallowed, version not newer, incompatible system, active or destructive work, store preparation failure, install deferral, relaunch pending, and update confirmation without inventing finer transport categories than the provider exposes.

Never log the private update key, public-key material, signature bytes, source-repository credentials, private feed tokens, credential-bearing URLs, full appcast or release-note bodies, archive paths, Slack credentials/content, feed content, prompts, model output, Vault content, database rows, or private user paths. Tests must prove expected success/failure/skipped events, stable reason codes, trace linkage, progress bounds, and sensitive-field absence before observability is considered verified.

## P6U verification gate

P6U uses two disposable builds with the same bundle identifier and approved Developer ID identity:

- installed baseline: 1.0.0 build 1;
- candidate: 1.0.1 build 2.

The candidate was Developer ID signed, Hardened Runtime enabled, and notarized for realistic replacement proof. A local HTTPS disposable server supplied a signed appcast, signed full archives, and bounded embedded notes. External release-note downloads remained disabled.

The completed gate required deterministic tests and disposable end-to-end evidence covering:

- channel selection and token-free feed resolution;
- automatic-check opt-in and no first-launch prompt;
- state transitions, implemented offline/feed-unavailable/provider-failure truth, download recovery, and notification/menu routing;
- signed-feed enforcement, correct EdDSA validation, wrong signature rejection, altered archive rejection, and no DSA;
- newer-version selection, older/same-version rejection, and wrong-channel rejection;
- full archive download through Sparkle's standard window, the traced 100-percent validation boundary, and no generated or consumed deltas;
- active-work and Delete All blocking, SwiftData save/quiescence, Vault SQLite close success/failure, one install handoff, real old-process termination, replacement, relaunch, and 1.0.1/build 2 confirmation;
- preservation of Vault data, source accounts, Keychain credentials, schedules, brief history, settings, and local-date behavior;
- truthful failure/recovery state and privacy-safe update traces.

The historical gate used two exported Developer ID/Hardened Runtime builds with the same bundle and signing authority against an EdDSA-signed, token-free local HTTPS route. The candidate's private notarization submission identifier and owner signing metadata are intentionally excluded from this public contract; stapling, Gatekeeper, and `syspolicy_check` passed for that historical candidate. Live UI checks rejected a beta route for stable, an older build, a wrong archive signature, and a byte-tampered archive before the valid archive was downloaded, installed, and relaunched as **Installed 1.0.1 (2)**. Linked unified logs captured signature validation, zero store blockers, store close, install handoff, and relaunch without private payloads. A signed-app-hosted preservation smoke covered disposable SwiftData, Vault, Data Protection Keychain, schedule, history, and local-date state and removed its fixture credential. Historical execution totals are intentionally not carried into the current candidate.

The exported-app launch initially exposed a missing Sparkle runtime search path
that XCTest had masked. The implementation added
`@executable_path/../Frameworks` to the app target and deterministic
project-setting coverage. Later private engineering work exercised disposable
signed-update and replacement behavior, but its internal proof artifacts,
operator paths, identifiers, and environment details are intentionally excluded
from this public source candidate. Those historical results do not certify a
new public binary. Any binary release must rerun the current deterministic
suite and a separately reviewed signing, notarization, update, preservation,
and clean-host verification gate on the exact release commit.

## Upstream authority

- Sparkle 2.9.4 release: <https://github.com/sparkle-project/Sparkle/releases/tag/2.9.4>
- Swift Package Manager manifest: <https://github.com/sparkle-project/Sparkle/blob/2.9.4/Package.swift>
- Basic setup and signing tools: <https://sparkle-project.org/documentation/>
- Sandboxed XPC integration: <https://sparkle-project.org/documentation/sandboxing/>
- Security and automatic-check settings: <https://sparkle-project.org/documentation/customization/>
- HTTPS/ATS requirements: <https://sparkle-project.org/documentation/app-transport-security/>
- Appcast, version, channel, and signing behavior: <https://sparkle-project.org/documentation/publishing/>
- Updater, delegate, and user-driver APIs: <https://sparkle-project.org/documentation/api-reference/>

STOP_CONDITION: stop after one verified private P6U commit/tag/private-main seal and report. Do not publish an appcast or artifact, create any release, restore the paused P6 release, or start a successor feature.
