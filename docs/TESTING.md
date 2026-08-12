# Testing

## Ordinary acceptance is fixture-only

Tests must use synthetic files, in-memory transports, disposable roots, and
mock provider responses. They must not read a real Slack, Discord, or email
account; production application stores; browser sessions; Keychain values; or
private attachments.

Live provider tests are explicit opt-in diagnostics. A skip caused by missing
live credentials is expected only for an allowlisted live test and does not
replace fixture coverage.

## Accepted local RC results

The local pre-seal acceptance runs produced this exact evidence:

- complete private native suite: 1,005 executed, 995 passed, 10 reviewed
  environment- or explicit-opt-in skips, 0 failed;
- focused authority/restart/semantic regression gate: 8 executed, 8 passed, 0
  skipped, 0 failed;
- selected three-class Attached Data integration matrix
  (`AttachedJSONSourceTests`, `ConnectorVaultAdmissionTests`, and
  `LokiChatControllerLifecycleTests`): 60 executed, 60 passed, 0 skipped,
  0 failed;
- pre-seal release-verifier inventory: 1,005 current XCTest methods, comprising
  all 905 methods from the annotated RC1 baseline plus 100 additions, with no
  baseline removal or duplicate;
- universal unsigned Debug build-for-testing and default Release: both passed
  for `arm64` and `x86_64`;
- disposable application smoke: 41 of 41 named tests passed, with no skip
  or failure and successful task-owned cleanup;
- exact-commit Node 22 build/test: pending the committed fixture CI workflow
  because the local Node 26 runtime is unsupported; and
- `scripts/verify-release.sh`: passed.

All ten native-suite skips were individually reviewed environment- or
explicit-opt-in gates. No skip was converted into a pass, and neither focused
run had a skip.

These runs used synthetic fixtures and task-owned disposable state. No live
credential, provider account, production store, remote Git operation, or
publication action was used. A final external verification record must bind
the results to commit, tag, and artifact identities after the local seal.

## Node.js tests

Use Node.js `>=22 <23`; CI selects Node 22. Do not substitute the host's Node
26: it is outside the package engine contract and cannot build the pinned
`better-sqlite3` 11.10.0 graph.

```sh
npm ci
npm run build
npm test
```

The legacy `npm run audit` command reruns the tests and writes a derived
`data/status.json`. Run it only in a disposable checkout when that derived
status is explicitly needed. It is not a package-vulnerability audit. A fresh
dependency vulnerability check is a separate authorized network operation
against configured package sources.

## Native tests

Use a disposable derived-data directory outside the repository:

```sh
xcodebuild \
  -project macos/LokiBrief/LokiBrief.xcodeproj \
  -scheme LokiBrief \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile \
  -skipPackageUpdates \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  DEVELOPMENT_TEAM= \
  CODE_SIGN_IDENTITY= \
  test
```

Set `DERIVED_DATA` to a fresh, explicitly bounded path. Do not use a production
container or store as a fixture.

## Static and baseline-identifier checks

Parse changed Swift files before compiling them. The release verifier compares
enabled XCTest identifiers with the annotated RC1 baseline and fails on any
baseline removal or duplicate:

```sh
find macos/LokiBrief -type f -name '*.swift' -print0 | xargs -0 swiftc -parse
```

The accepted pre-seal inventory contained all 905 baseline methods plus 100 new
methods, for 1,005 current methods. No rename mapping was used. Final proof
records the current identifiers and actual execution results; it never treats
a historical total as an execution pass.

## Release checks

```sh
scripts/check-secrets.sh
scripts/verify-release.sh
scripts/generate-dependency-inventory.sh
```

The checks report classifications and paths, never matched secret values. They
must pass on the exact candidate commit without relying on historical test
totals.

The canonical private repository runs the default verifier so the annotated
RC1 baseline remains available for identifier comparison. The intentionally
one-commit, remote-free publication repository instead runs:

```sh
scripts/verify-release.sh --public-clean-history
```

That explicit mode requires exactly `main` plus the annotated RC3 tag, both at
the one root commit, no remotes, and the accepted 1,005-method inventory. The
separate publication-repository verifier must still prove exact tree equality
with the canonical tag whose default release verification preserves RC1.

## Connector minimums

Slack regressions, Discord read-only behavior, Support Email parsing, source
authority, provenance, cancellation, disconnect/deletion, and sensitive-field
absence require deterministic fixture coverage. See `CONNECTORS.md`.

## Disposable application smoke

After fixture suites and universal builds pass, run the bounded named XCTest
matrix:

```sh
scripts/run-disposable-app-smoke.sh
```

The runner creates task-owned temporary DerivedData and isolated store roots
outside the repository. It selects exact hooks for first launch/onboarding,
Sources, Slack, native Discord REST, local Email files, provenance/search,
cancellation, restart/persistence, disconnect/removal, and graceful unavailable
states. The first-launch hook constructs isolated on-disk SwiftData and Vault
stores and confirms empty connector state plus Sources/About navigation. About,
source/native versions, and Apache-2.0 copy are asserted statically because
there is no UI automation target for that view.

The manifest is fail-closed: a missing source, class, or method stops before
`xcodebuild`. `--preflight-only` checks that manifest and the static About copy;
it is not an executed smoke result. The full command disables package updates,
live-provider opt-ins, signing, and parallel testing. It neither contacts live
accounts nor replaces or launches the installed application. Tests run from
disposable build products with synthetic transports and local fixture files.

Record the exact commit/toolchain, named selectors, disposable-root
classification, result, and cleanup outcome without recording the private root
path or fixture bodies. The accepted RC3 pre-seal run executed all 41 named
tests: 41 passed, 0 skipped, and 0 failed. Its task-owned build/store state
was cleaned up, the installed application was untouched, and no live provider
or network opt-in was enabled.

## CI assumptions

The fixture workflow separates offline release hygiene from build/test. Its
compatibility job uses `macos-15`, selects Xcode 16.4 through `DEVELOPER_DIR`,
selects Node.js 22, disables live-provider opt-ins, builds a universal Debug
test bundle, runs fixtures, and builds universal Release. GitHub has not run the
candidate workflow yet, so its truthful state is `READY_TO_RUN`.

## Reporting results

Record the command, exact commit, runtime/toolchain, executed/passed/skipped/
failed counts reported by that run, and any unrun check. Never copy an older
count into a new acceptance report.
