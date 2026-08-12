# Loki Brief 1.0.0 RC1 Release Checklist

Historical P6/P6U private-binary evidence. Current open-source candidate gates
are in [`PUBLICATION_CHECKLIST.md`](PUBLICATION_CHECKLIST.md). Checked items here
cannot certify the changed source tree or a new binary.

Unchecked items are blocking. This checklist records evidence; it does not authorize publication.

## P6R release hold

The final P6 release is paused. The accepted notarized RC1 artifact is a superseded private engineering proof only: it must not be published, attached to a GitHub release, or used to create a public or private release. P6R authorizes no final P6 tag and no replacement archive, DMG, or notarization submission. Any changed build is a new artifact with a new hash and cannot reuse the previous notarization submission.

This checklist is retained as historical P6 preparation evidence. Its remaining unchecked items are neither P6R requirements nor authorization to resume the release. P6R ended at its private local-date product-scope checkpoint and report; P6U separately authorizes only its disposable update artifacts and proof.

## P6U secure-update foundation hold

P6U is a separate private foundation gate governed by `docs/LOKI_BRIEF_P6U_SECURE_UPDATE_CONTRACT.md`. The implementation and disposable live-proof items below passed on 2026-07-20. They are not release authorization; the checked private commit/tag line is valid only with the containing commit, annotated-tag object/peel, private-main containment, and remote-ref proof recorded in the P6U closeout.

- [x] Sparkle 2.9.4 is pinned from the official package URL and the final package graph/product is audited.
- [x] The sandboxed exported app enables bundled Installer.xpc, omits Downloader.xpc enablement, carries only the required `-spks`/`-spki` mach exceptions, loads Sparkle through `@executable_path/../Frameworks`, and preserves Developer ID, Hardened Runtime, and the app-specific Keychain group.
- [x] Stable/beta/internal selection, token-free HTTPS feed resolution, stable-only acceptance for stable, stable-plus-selected-channel acceptance for beta/internal, and wrong-channel rejection pass deterministic tests.
- [x] Automatic checks default off, no first-launch permission prompt occurs, manual Check for Updates remains available, and automatic install stays disabled.
- [x] The historical Sparkle EdDSA key was custody-audited without reading the private value into proof output. Its owner-specific account, public key, and fingerprint are intentionally absent from this public source tree.
- [x] `SUVerifyUpdateBeforeExtraction`, `SURequireSignedFeed`, and strict non-expiring signed-feed failure behavior are verified; DSA is absent.
- [x] Historical `generate_appcast --maximum-deltas 0` proof produced a signed appcast and full archive with bounded embedded notes, no external release-note download, and no delta file or delta entry; its operator account remained outside public evidence.
- [x] The disposable 1.0.0/build 1 baseline discovered and downloaded the signed 1.0.1/build 2 candidate over disposable HTTPS; wrong archive signatures, byte-altered archives, older versions, and wrong channels were rejected.
- [x] Active work and Delete All block install safely; SwiftData saves/quiesces and Vault SQLite closes before one install handoff; real old-process termination releases in-process SwiftData resources; app replacement and relaunch confirmed 1.0.1/build 2.
- [x] Disposable Vault data, source accounts, Data Protection Keychain credentials, schedules, brief history, settings, and local-date behavior survived the update and the disposable fixture credential was removed.
- [x] Offline, feed-unavailable, failed-download, failed-readiness, install, relaunch, and recovery states remain truthful and privacy-safe update traces pass redaction tests.
- [x] The final update candidate has the same bundle identifier and approved Developer ID identity, Hardened Runtime, and accepted notarization/stapling/Gatekeeper/`syspolicy_check` proof.
- [x] The private source repository remains private; held production data remained untouched; the pre-proof app/data state was restored and its post-relaunch state re-isolated/restored exactly; the disposable HTTPS trust/server was removed; production appcast, public artifact/host, and GitHub release remain unpublished.
- [x] Exactly one P6U commit and annotated private tag are created only after all proof passes; only private `main` and that tag are pushed.

## Identity and policy

- [x] Product/version/build/bundle/minimum OS declared as Loki Brief 1.0.0, build 1, `com.agentloki.LokiBrief`, macOS 14.0.
- [x] Free early-access entitlement policy implemented without billing or Loki account.
- [x] Approved icon source/master/catalog hashes preserved in the icon checkpoint.
- [x] Final icon compilation and release-bundle rendition audit passed: ten compiled renditions plus the catalog metadata record; source/master/output hashes match the approved checkpoint.

## Source and regression verification

- [x] The historical P6 packet recorded focused, native, and P2-P5 regression
  suites as passed. Its totals are intentionally omitted because they do not
  describe the current candidate; current results belong in the new release
  packet.
- [x] Release-signed Data Protection Keychain create/read/atomic-replace/cross-process-read/delete/not-found smoke passed with the exact final access group.
- [x] The historical isolated Node install/build/test packet passed. Dependency
  and vulnerability state is time-sensitive and must be refreshed for the
  current candidate rather than inherited from this checklist.
- [x] High-confidence credential/private-key secret scan passed.
- [x] Profile, certificate, Keychain file, DMG, package, archive, result-bundle, database, and generated-release-artifact exclusion scans passed for the repository.
- [x] Public-facing release-document private-path scan and mandatory-document inventory passed.
- [x] Project/plist/catalog lint, approved-icon hash/dimension/alpha audit, and release-bundle content scan passed.

## Slack

- [x] Checked-in manifest has exact callback, PKCE, token rotation, five user scopes, and no bot scopes.
- [x] Approved public release Client ID supplied through ignored local configuration and verified without printing it.
- [x] Dashboard configuration read back without secrets: exact callback, PKCE, token rotation, five required user scopes, and zero bot scopes.
- [ ] Live system-browser callback, identity, one non-sensitive channel, at-most-15 retrieval, deterministic attribution, consent-off Ollama boundary, disconnect/preserve decision, and deletion proof passed.

## Signing and artifact

- [x] Existing Developer ID Application identity and private key found.
- [x] Disposable Developer ID signing/timestamp probe passed and was removed.
- [x] App-specific Developer ID direct-distribution profile installed: exact application identifier; Apple-signed wildcard Keychain allowlist authorizes the app's exact final Keychain claim.
- [ ] Current release operator supplies the reviewed team, Developer ID identity, and any explicit export selection through ignored local or task-owned inputs. No owner-specific team identifier or certificate fingerprint is committed.
- [ ] Fresh final release archive/export embeds the approved Slack configuration and is universal, Hardened Runtime, securely timestamped with the approved identity, exact-entitled, and free of debug/test content. The earlier pre-notary export is superseded because its Client ID is empty.
- [ ] Every configured update feed has the release operator's matching 32-byte Ed25519 public key injected through ignored local or task-owned configuration; the private key and owner-specific public-key fingerprint remain outside the repository.
- [ ] Final DMG contains only Loki Brief.app and Applications link.
- [ ] Notary submission status is `Accepted`; log reviewed.
- [ ] App/DMG stapling and validation passed.
- [ ] Gatekeeper and `syspolicy_check distribution` passed where supported.

## Install, upgrade, and uninstall

- [ ] Approved disposable standard user or macOS VM is available.
- [ ] Quarantined clean install and first run passed with all opt-ins off.
- [ ] Upgrade from valid disposable P5 data preserved every required surface.
- [ ] Disposable uninstall removed process, login registration, pending notifications, test credential/archive/export, and app bundle.
- [ ] Operator production data remained untouched.

## Seal and private distribution

- [ ] Final diff reviewed; exactly one P6 commit created.
- [ ] Annotated P6 tag created and peeled proof recorded.
- [ ] Local `main` fast-forwarded; only private `origin/main` and tag pushed.
- [ ] Public provenance and disabled public push reverified.
- [ ] External manifest and checksums generated after final commit/tag.
- [ ] Private draft release created; draft state, assets, sizes, hashes, and private visibility read back.
- [ ] No public URL, announcement, visibility change, or external distribution occurred.
