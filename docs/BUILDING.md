# Building

## Requirements

- deployment target macOS 14.0 or later;
- locally verified release-preparation toolchain: macOS 26.6, Xcode 26.6
  (`17F113`), Swift 6.3.3;
- compatibility CI target: GitHub's `macos-15` runner with
  `/Applications/Xcode_16.4.app/Contents/Developer` selected explicitly;
- Git;
- Node.js `>=22 <23` for the legacy TypeScript runtime. Fixture CI selects Node
  22. The local host's Node 26 is outside the supported engine range and cannot
  build the pinned `better-sqlite3` 11.10.0 graph, so it is not release
  evidence.

The native app and legacy Node runtime are independent build surfaces.
The Xcode 16.4 CI lane is configured but not yet remotely executed. Treat it as
`READY_TO_RUN`, not as compatibility proof, until GitHub reports a result.
The project currently sets `SWIFT_VERSION = 5.0`, meaning Swift 5 language
compatibility mode; the locally observed Swift 6.3.3 value names the compiler
toolchain and does not claim Swift 6 language mode.

## Current local build evidence

The RC3 private pre-seal acceptance runs verified native version `1.0.0`,
build `3`. The universal Debug build-for-testing and default Release
application both passed for `arm64` and `x86_64` with Apple signing disabled.
The complete native suite
executed 1,005 tests (995 passed, 10 reviewed skips, 0 failed). The focused
authority/restart/semantic gate passed 8 of 8, and the selected three-class
Attached Data integration matrix passed 60 of 60. The disposable application smoke
passed 41 of 41 named tests and completed task-owned cleanup. Exact-commit
Node 22 build/test evidence is delegated to the fixture CI workflow because the
local Node 26 runtime is unsupported.

The pre-seal release verifier also accepted an XCTest inventory of 1,005:
905 identifiers from the annotated RC1 baseline plus 100 additions. This is
local source-build evidence without Apple distribution signing, not final tag
or artifact identity.
Remote CI has never run and remains `READY_TO_RUN`; the unsigned output has no
Developer ID distribution signature. Binary status remains
`BINARY_DISTRIBUTION_PENDING_SIGNING`.

## Clone and dependency safety

Use only the public sanitized repository or source archive. Do not use private
development-history refs as a dependency. Review `Package.resolved` and
`package-lock.json` before allowing package-source network access.

Release verification scripts do not install dependencies or contact the
network. `npm ci` and the first Swift package build may contact their configured
package sources.

## Native macOS app

From the repository root:

```sh
xcodebuild \
  -project macos/LokiBrief/LokiBrief.xcodeproj \
  -scheme LokiBrief \
  -configuration Debug \
  -destination 'platform=macOS' \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile \
  -skipPackageUpdates \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  DEVELOPMENT_TEAM= \
  CODE_SIGN_IDENTITY= \
  build
```

This build disables Xcode code signing and is sufficient for source
compilation. A current linker may still attach a non-distribution ad-hoc linker
signature. The result is not a distributable binary and does not prove Keychain
entitlements, Developer ID, notarization, or Gatekeeper acceptance.

A clean checkout supplies no Apple team, signing identity, Slack client ID,
update feed, or update public key. Its project defaults disable Xcode code
signing; the explicit no-signing arguments above are defense in depth for
reproducible source builds.

Machine/operator configuration belongs only in ignored local files copied from
the checked-in examples:

```sh
cp macos/LokiBrief/Config/Slack.example.xcconfig \
  macos/LokiBrief/Config/Slack.local.xcconfig
cp macos/LokiBrief/Config/Signing.example.xcconfig \
  macos/LokiBrief/Config/Signing.local.xcconfig
cp macos/LokiBrief/Config/Updates.example.xcconfig \
  macos/LokiBrief/Config/Updates.local.xcconfig
```

Create only the files you need. Slack configuration must never include a
client secret. Update feeds must be token-free HTTPS URLs, and any configured
feed requires the matching base64-encoded 32-byte Ed25519 public key in
`LOKI_UPDATE_PUBLIC_ED_KEY`. The corresponding private key never belongs in an
xcconfig, environment file, repository, build log, or app bundle.

`Signing.local.xcconfig` is for interactive development. A distribution gate
should instead pass its Apple team and selected certificate to that one
`xcodebuild` invocation, together with `CODE_SIGNING_ALLOWED=YES`,
`CODE_SIGNING_REQUIRED=YES`, and the reviewed `CODE_SIGN_STYLE`. Do not write
those owner values into the project file or a checked-in xcconfig.

The checked-in `Config/ExportOptions-DeveloperID.plist` is also owner-neutral.
If export requires an explicit `teamID` or `signingCertificate`, add them to a
task-owned temporary copy or the ignored
`Config/ExportOptions-DeveloperID.local.plist`, use that copy for
`xcodebuild -exportArchive`, and remove the task-owned copy at release-gate
cleanup. Never patch the checked-in template with a real operator value.

## Legacy TypeScript Discord bot

Install the exact lockfile graph and compile:

```sh
npm ci
npm run build
```

Do not run `npm run register` or `npm run start` during an ordinary build. Those
commands contact Discord and require an explicitly isolated bot and guild. The
legacy runtime is write-capable even when moderation enforcement is disabled.

## Universal source-build checks

For release acceptance, build the Debug test bundle and the default Release
application for both native architectures with Xcode code signing disabled. Set `DERIVED_DATA`
and `RELEASE_DERIVED_DATA` to fresh absolute directories outside the repository.

```sh
xcodebuild \
  -project macos/LokiBrief/LokiBrief.xcodeproj \
  -scheme LokiBrief \
  -configuration Debug \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile \
  -skipPackageUpdates \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  DEVELOPMENT_TEAM= \
  CODE_SIGN_IDENTITY= \
  ONLY_ACTIVE_ARCH=NO \
  'ARCHS=arm64 x86_64' \
  build-for-testing
```

```sh
xcodebuild \
  -project macos/LokiBrief/LokiBrief.xcodeproj \
  -scheme LokiBrief \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$RELEASE_DERIVED_DATA" \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile \
  -skipPackageUpdates \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  DEVELOPMENT_TEAM= \
  CODE_SIGN_IDENTITY= \
  ONLY_ACTIVE_ARCH=NO \
  'ARCHS=arm64 x86_64' \
  build
```

A build with Xcode code signing disabled proves source compilation only, even
if the linker adds an ad-hoc linker signature. Confirm the reported
architectures with `lipo -archs` against the built executable before recording
universal-build proof.
