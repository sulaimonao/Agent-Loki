# Loki Brief Slack connector setup

This setup includes historical P3-P6 proof language. Current source-RC
acceptance treats live Slack access as optional; deterministic fixture
regressions remain mandatory. Never use a real workspace without separate
authorization.

This setup creates public configuration for a read-only external source connector. It does not create a Loki login and never uses a client secret.

## 1. Create or update the Slack app

Import [`config/slack/loki-brief-slack-app-manifest.yaml`](../config/slack/loki-brief-slack-app-manifest.yaml) in Slack's app configuration UI, or copy its settings exactly.

Confirm:

- display name is `Loki Brief`;
- PKCE is enabled (Slack treats this public-client choice as permanent unless Slack Support intervenes);
- token rotation is enabled;
- redirect URL is exactly `com.agentloki.lokibrief://oauth/slack`;
- user scopes are exactly `channels:read`, `channels:history`, `groups:read`, `groups:history`, and `users:read`;
- there are no bot scopes or bot user;
- Socket Mode, Events API, interactivity, incoming webhooks, and organization deployment are off.

For a custom URI-scheme desktop redirect, Slack requires S256 PKCE, forbids bot scopes, and issues rotating tokens without a client secret. Access tokens expire after 12 hours; PKCE refresh tokens expire after 30 days and are single-use after a short grace period. Do not enable Slack Public Distribution for this private candidate because it creates a shareable installation URL.

Do not add Sign in with Slack/OpenID scopes, `im:read`, `im:history`, `mpim:read`, `mpim:history`, `files:read`, `search:read`, `reactions:read`, `users:read.email`, `chat:write`, or any other write scope.

## 2. Configure the public client ID locally

From the repository root:

```bash
cp macos/LokiBrief/Config/Slack.example.xcconfig macos/LokiBrief/Config/Slack.local.xcconfig
```

Edit only the ignored local file and set the Slack app's Client ID:

```text
LOKI_SLACK_CLIENT_ID = 1234567890.1234567890
```

The client ID is not secret, but the local file stays untracked so machine-specific application configuration cannot be mistaken for a portable tested default. Never place a client secret, token, code, verifier, or refresh credential in an xcconfig, environment file, Info.plist, manifest, source file, test fixture, or command output.

Without a configured client ID, Loki Brief builds and launches normally and shows **Slack configuration required**. Feed and Ollama behavior remains available.

## 3. Optionally sign a development build, then build and test

A clean checkout builds with Xcode code signing disabled and contains no Apple
team or certificate selection. A current linker may still attach an ad-hoc
linker signature; that is sufficient for normal source compilation and fixture
tests but not for the Data Protection Keychain smoke. For that smoke, copy
`Config/Signing.example.xcconfig` to the ignored
`Config/Signing.local.xcconfig`, replace the team placeholder, and let Xcode use
that operator's Apple Development identity and profile. No team value,
certificate fingerprint, private key, Apple account, or provisioning profile
belongs in this repository.

On an authorized development Mac:

```bash
xcodebuild -project macos/LokiBrief/LokiBrief.xcodeproj \
  -scheme LokiBrief \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/LokiBriefP3Build \
  -allowProvisioningUpdates \
  ONLY_ACTIVE_ARCH=NO clean build

xcodebuild -project macos/LokiBrief/LokiBrief.xcodeproj \
  -scheme LokiBrief \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/LokiBriefP3Tests \
  -allowProvisioningUpdates test

export LOKI_KEYCHAIN_SMOKE_NAMESPACE="P3$(uuidgen | tr -d '-')"
LOKI_KEYCHAIN_SMOKE_PHASE=seed xcodebuild \
  -project macos/LokiBrief/LokiBrief.xcodeproj \
  -scheme LokiBrief -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/LokiBriefP3KeychainRelaunch \
  -allowProvisioningUpdates test \
  -only-testing:LokiBriefTests/SlackCredentialStoreTests/testIsolatedDataProtectionKeychainCreateReadReplaceDeleteSmoke
LOKI_KEYCHAIN_SMOKE_PHASE=read_cleanup xcodebuild \
  -project macos/LokiBrief/LokiBrief.xcodeproj \
  -scheme LokiBrief -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/LokiBriefP3KeychainRelaunch \
  -allowProvisioningUpdates test \
  -only-testing:LokiBriefTests/SlackCredentialStoreTests/testIsolatedDataProtectionKeychainCreateReadReplaceDeleteSmoke
```

Always run the `read_cleanup` phase after `seed`, including after a failed seed attempt. DerivedData and Xcode-managed development assets stay outside the repository. The isolated smoke uses the production Data Protection Keychain path, a unique test-only service name, atomic replacement, a separate-process relaunch read, deletion, and not-found verification. It removes its test record before completion.

Remove `Signing.local.xcconfig` when the local override is no longer needed.
This development proof is not release readiness. Distribution additionally
requires a freshly selected Developer ID identity supplied outside the
repository, an app-specific distribution profile, Hardened Runtime
reconciliation, notarization, stapling, Gatekeeper, and disposable
install/upgrade/uninstall proof.

## 4. Connect a workspace

1. Open **Sources**.
2. Under **Slack**, choose **Connect Slack**.
3. Complete the system browser authorization for the intended workspace.
4. Inspect the authenticated workspace/user identity and granted scopes.
5. Choose **Choose Channels**.
6. Select only the public/private channels intended for local briefing evidence; selection defaults to none and is capped at 20.
7. Choose **Refresh Selected Channels**.

Slack's restrictive history class can allow only one 15-message request per minute. Loki Brief displays queued/rate-limited work and obeys `Retry-After`; canceling a refresh stops pending waits and preserves partial success.

No channel content is sent to Ollama by default. To permit selected bounded content for one workspace, explicitly enable **Allow local-model processing of selected Slack content** on that workspace. Disabling it is immediate and cancels affected in-flight generation.

## 5. Disconnect or delete local Slack data

**Disable Workspace** retains local metadata but prevents refresh. **Delete Slack Data** removes local evidence, cursors, selections, and generated Slack presentation for that workspace. **Disconnect Slack** also attempts bounded access-token revocation and removes the complete Keychain credential envelope.

Local disconnection completes even if Slack is offline. `auth.revoke` revokes a token but is not a guaranteed Slack app uninstall. If the installation must disappear from the workspace, remove the app separately in Slack's app-management UI.

Unrelated feed subscriptions, feed evidence, settings, brief history without the removed Slack evidence, and Ollama configuration remain intact.

## P6 live smoke gate

The historical P6 binary gate required a bounded live proof. The current source
RC does not: when separately authorized, use the Client ID, matching PKCE app,
authenticated system-browser session, and one explicitly selected non-sensitive
channel. Retrieve at most 15 synthetic messages, verify deterministic
attribution and the consent-off Ollama boundary, then disconnect and prove
separate local deletion. Reports never include tokens, message bodies, channel
names, account email, private URLs, or other private content.

Safe structured Slack events are available through macOS unified logging under subsystem `com.agentloki.LokiBrief` and category `slack`. Their JSON metadata is closed to bounded counts, operation names, and hashed identifiers; it excludes Slack content and credentials.
