# Install, Upgrade, and Uninstall Loki Brief

The DMG instructions below are historical private-binary guidance; no signed or
notarized binary is included in the open-source candidate. Build unsigned source
with [`BUILDING.md`](BUILDING.md). Use these DMG steps only for a future exact
binary that has separately passed signing, notarization, checksum, and
publication review. The local-data cleanup guidance remains applicable.

## Install

1. Obtain `Loki-Brief-1.0.0-rc.1.dmg` and `SHA256SUMS.txt` from the approved private release.
2. Verify the DMG SHA-256 against `SHA256SUMS.txt`.
3. Open the DMG and drag **Loki Brief.app** to **Applications**.
4. Launch normally. Do not disable Gatekeeper and do not use a bypass as a substitute for a valid signature/notarization ticket.

No Apple ID, Loki account, payment, license key, or installer package is required. Scheduling, notifications, Launch at Login, and Ollama are off by default.

## Upgrade

Quit the prior app, replace only the application bundle, and relaunch. A valid upgrade must preserve briefs, Vault metadata/content, settings, source metadata, schedule state, and terminal delivery history. Never delete the data container to repair a migration. If migration reports a degraded state, preserve the original files and stop.

## Remove connected data before uninstalling

When complete cleanup is desired:

1. Disconnect configured sources and revoke credentials where offered.
2. Turn off Launch at Login.
3. Disable delivery notifications and remove pending Loki Brief notifications.
4. Export anything you intend to keep.
5. Use **Delete All Local Data** and confirm the result.
6. Remove any completed test/user exports separately; deliberate completed exports are not silently deleted.
7. Quit Loki Brief.

## Remove the app

Move **Loki Brief.app** from Applications to Trash. Verify no Loki Brief process remains, no Background Items registration remains, no Loki Brief credential remains in Keychain, and no test export/notification/archive remains.

Deleting the application bundle alone does not necessarily delete SwiftData, Loki Vault files, completed exports, Keychain credentials, notification records, or Launch at Login registration.
