# Loki Brief 1.0.0 RC1 Release Notes

Historical private-candidate notes, superseded for source-release status by
[`RELEASE_NOTES_1.0.0_RC1.md`](RELEASE_NOTES_1.0.0_RC1.md). The prior P6/P6U
binary/update evidence does not make a current binary distributable.

## Highlights

- Native local-first daily briefing for public feeds and approved read-only Slack selected channels.
- Deterministic attributable briefing is always available; optional Ollama presentation remains local loopback.
- Loki Vault provides local SQLite archive, search, retention, storage reporting, deterministic export, and bounded historical backfill.
- One while-running daily schedule supports bounded forward refresh, local notifications, run history, and optional Launch at Login.
- Approved production icon and universal macOS app identity.

Every implemented local feature is available without payment, subscription, Loki account, license key, receipt validation, or cloud entitlement. Future paid features are not yet offered; no billing provider is configured.

## Secure-update status

Secure self-update is not a shipped RC1 feature and no production appcast, archive host, download URL, or automatic-update service is available. P6U privately implemented and proved an exact Sparkle 2.9.4, EdDSA-signed, full-archive path from disposable 1.0.0/build 1 to 1.0.1/build 2. It excludes DSA, deltas, tokenized/private-GitHub archive URLs, and external release-note downloads; keeps automatic checking off unless the user explicitly opts in; keeps automatic installation off; and does not authorize publication or distribution. See [the P6U contract](LOKI_BRIEF_P6U_SECURE_UPDATE_CONTRACT.md).

## Requirements and installation

The historical binary targeted macOS 14.0 or later on Apple silicon or Intel.
There is no current notarized DMG. Build the source candidate using
[`BUILDING.md`](BUILDING.md); do not bypass Gatekeeper for any future binary.

## Privacy

Source data, brief history, settings, and Vault data remain local. Credentials use Keychain. Vault and exports are not application-level encrypted; FileVault is recommended. Loki operates no cloud account, telemetry, analytics, advertising, data sale, cloud archive, or cloud-model fallback for this app.

## Sources

Feeds begin at saved public HTTPS URLs and may follow only bounded redirects whose targets independently pass the same public-HTTPS and network-safety checks. Slack requires the approved private Client ID, exact callback, PKCE, rotating user tokens, and five read-only user scopes; DMs, files, posting, bots, Socket Mode, Events API, webhooks, and OpenID login are excluded. RC1 cannot seal until the bounded live Slack flow passes without exposing private content.

## Known limitations

- Scheduling runs only while Loki Brief is active; quitting pauses delivery.
- Ollama must be installed and configured separately.
- Slack requires the approved release configuration plus explicit user authorization and selected-channel setup.
- No disposable clean-install claim is valid until tested outside the operator's production account.
- Private RC1 documents and Slack configuration are approved; public privacy/support routes, patent/publication decisions, download destination, and public-launch authorization remain pending.

## Checksums and support

If P6 is separately resumed and completed, verify its final DMG and release manifest using `SHA256SUMS.txt`. The approved support route is pending and must exist before external distribution. P6U does not change this hold; Loki Brief remains private and prepublication-only.
