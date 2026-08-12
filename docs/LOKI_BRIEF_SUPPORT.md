# Loki Brief Support

Historical private-candidate support notes. Current public support routes and
limitations are defined by [`SUPPORT.md`](../SUPPORT.md). Statements below about
the paused private DMG/update gate remain historical evidence, not current
source-release status.

## Historical candidate baseline

- Product: Loki Brief 1.0.0 RC1
- Build: 1
- macOS: 14.0 or later
- Architectures: Apple silicon (`arm64`) and Intel (`x86_64`)
- Distribution: not approved; the prior private Developer ID/notarized DMG path remains paused with P6

Loki Brief does not require an Apple ID, Loki account, subscription, payment, or license key. Slack and Ollama are optional; Slack requires approved application configuration and authorization, and Ollama requires a separately installed local service/model.

## Safe diagnostic information

An approved support interaction may request app version/build, macOS version, affected surface, time of failure, consumer-visible message, and redacted structured event/status/reason fields. Never send Slack tokens, authorization codes, private keys, provisioning profiles, message bodies, channel names, feed contents, private URLs, Vault exports, prompts, or raw databases.

## Known candidate limitations

- Slack remains disconnected until the user explicitly authorizes the workspace and selects one or more permitted channels.
- Delivery runs only while the main menu-bar app is active; quitting pauses it.
- Ollama is optional and local-only.
- Vault data and exports are not application-level encrypted.
- Deleting the app bundle alone does not necessarily remove local data, exports, Launch at Login registration, notifications, or Keychain credentials.

## P6U update support and recovery

P6U does not establish a production update service, public appcast, public download route, or support entitlement. Its disposable 1.0.0/build 1 to 1.0.1/build 2 proof passed through the exact Sparkle 2.9.4 full-archive path on an isolated token-free HTTPS origin while held production state remained untouched. That proof does not make either disposable build distributable. Automatic checking remains off unless the user explicitly opts in; automatic installation remains off.

For an update failure, collect only the existing safe diagnostic fields plus update channel, current and offered version/build, lifecycle state, the bounded download-start/validated-100-percent boundary, install-readiness state, replacement/relaunch receipt outcome, and stable redacted reason codes. Traces—not the receipt—are authoritative for check/feed/archive/install/relaunch validation. Do not promise distinct DNS/TLS/HTTP/malformed-feed diagnoses when the implemented category is `offline`, `feed_unavailable`, `download_failed`, or `provider_failure`. Never request an appcast/release-note body, archive bytes, signing-key value, tokenized URL, raw private payload, or user content. A retry must be explicit and must not bypass signature, channel, HTTPS, sandbox, notarization, or readiness checks.

Do not use **Delete All Local Data**, container removal, Keychain clearing, or an unverified downgrade as first-line recovery. There is no automatic rollback guarantee. Stop further distribution—including on update-key loss—preserve the sandbox container and Keychain items, and use only a separately reviewed operator-approved signed/notarized higher recovery build or other explicitly authorized non-destructive release path with established storage compatibility. Replacing or reinstalling the app bundle must preserve data and credentials and is not, by itself, proof that rollback or signing-key recovery is safe. Escalate any launch, migration, or store-reopen failure with the redacted trace/reason evidence and the exact recovery artifact identity.

## Support route

Pending explicit operator approval. This field must be replaced with an approved route before any public launch or production update service; no address or service should be inferred from repository metadata.
