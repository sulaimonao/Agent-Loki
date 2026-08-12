# Loki Brief public runbook

This runbook covers source-candidate checks and safe local operation. It does
not certify a signed or notarized binary. Start with [Building](BUILDING.md),
[Testing](TESTING.md), and [Releasing](RELEASING.md).

## Candidate status

- Native Slack behavior is preserved and remains read-only.
- The native macOS read-only REST Discord connector and local Email import are
  verified source-candidate features.
- IMAP is deferred; it is not part of this release candidate.
- Live Slack, Discord, and email account smokes were not run; they remain
  optional credentialed checks and do not replace fixture evidence.
- The legacy root TypeScript Discord Gateway/moderation runtime is a separate,
  write-capable component. It is not the native macOS REST connector and must
  not be represented as Connector V1.
- A source release candidate may be unsigned. Any distributed application
  binary requires a separate signing, notarization, packaging, and clean-host
  verification gate.
- Local candidate preparation uses macOS 26.6/Xcode 26.6 (`17F113`). Fixture CI
  selects Xcode 16.4 on `macos-15` but remains `READY_TO_RUN` until GitHub
  executes it.
- The legacy Node runtime requires `>=22 <23`; CI selects Node 22. The local
  Node 26 runtime is unsupported and must not be substituted for release
  verification.

## Source-candidate verification

From the repository root, run:

```sh
scripts/verify-release.sh --allow-dirty
scripts/check-secrets.sh
scripts/generate-dependency-inventory.sh \
  --output /absolute/output/directory/dependency-inventory.md
```

Use `--allow-dirty` only while preparing the candidate. Final release
verification must run without it from the exact clean commit to be archived.
The secret checker reports classifications and locations, never matched values.
Treat every finding as a review blocker until it is explained or removed.

The dependency inventory is generated offline from committed lockfiles. Review
every reported license against the exact pinned source before publication; the
generated inventory is evidence, not automatic legal approval.

After the complete fixture suite and universal builds pass, run:

```sh
scripts/run-disposable-app-smoke.sh
```

This executes the exact synthetic first-launch, Sources/connector,
provenance/search, cancellation, persistence, removal, and unavailable-state
XCTest matrix in task-owned temporary DerivedData/store roots. It checks About,
source/native version, and Apache-2.0 text statically. A missing named hook is a
failure; `--preflight-only` does not satisfy the smoke gate. It uses no live
account, does not resolve packages, and does not replace the installed app.

## Native application workflow

1. Build and run the macOS application using the pinned package resolution and
   the commands in [Building](BUILDING.md).
2. Add a public HTTPS feed or configure an already-approved local fixture.
3. If using Slack, follow [Slack setup](LOKI_BRIEF_SLACK_SETUP.md), select only
   intended channels, and keep optional local-model sharing disabled unless the
   content is suitable for that use.
4. Keep Ollama optional. The native app uses fixed loopback endpoints and does
   not install, pull, delete, or manage models.
5. Inspect local Vault, retention, export, schedule, notification, and deletion
   behavior only with disposable data during release testing.
6. Confirm logs and diagnostics contain bounded state, reason codes, and counts
   rather than messages, prompts, tokens, account names, or private paths.

Slack refresh does not join channels or post messages. Feed refresh does not
fetch linked article bodies. Native connector work must preserve the same
read-only, least-privilege, bounded-fetch posture.

## Connector validation

Use fixture and mock-backed tests first. Do not place live credentials in the
repository, command history, test output, screenshots, or issue reports.

Native Discord and local Email source-candidate acceptance includes all of the
following:

- deterministic parsing, normalization, pagination, cancellation, and
  persistence tests;
- explicit read-only authorization and redacted diagnostics;
- migration and deletion coverage for connector-owned data;
- a documented optional live smoke plan; and
- independent review of the implementation and resulting evidence.

Those fixture, migration, deletion, universal-build, disposable-smoke, and
review gates passed for this source candidate. Live-account smokes remain
unrun and optional.

The precise optional Discord and local Email procedures are in
[`CONNECTORS.md`](CONNECTORS.md). Missing live credentials is recorded as unrun
and does not replace fixture proof.

Live-account smokes are intentionally outside fixture CI. When separately
authorized, use disposable accounts or messages, record classification-only
results, remove credentials afterward, and never commit the evidence payload.

## Local data and recovery

Application data belongs in the app sandbox and system credential storage, not
in the repository. Before testing destructive controls such as account removal,
retention, archive deletion, or Delete All, use disposable data and confirm the
exact scope shown by the UI. Do not reset or replace a failed store
automatically.

If the app reports an integrity, migration, credential, or connector failure,
stop the affected operation, preserve the current data, and capture only a
redacted reason code and reproducible fixture case. Security-sensitive reports
follow [SECURITY.md](../SECURITY.md).

## Public source packaging

After the canonical tag is sealed, create and verify the fresh standalone
remote-free public repository described in [Releasing](RELEASING.md). Then,
from that clean public repository's exact annotated tag, create the source
archive and SBOM outside both repositories:

```sh
scripts/package-source-release.sh \
  --output-dir /absolute/output/directory \
  --tag v1.0.0-rc.3
scripts/generate-sbom.sh \
  --tag v1.0.0-rc.3 \
  --artifact-root /absolute/output/directory
```

Inspect and reproduce the archive and parse the SPDX 2.3 document. Do not
generate the final SHA256SUMS separately: `prepare-github-release.sh` requires
that path to be absent, creates it after the release manifest is final, and
reproduces and verifies every entry. Publication uses only this clean public
history and public-tag source packet; it does not change the visibility of the
private development repository or publish its history.

See [Publication checklist](PUBLICATION_CHECKLIST.md) and
[Security review](SECURITY_REVIEW.md) for the final human gates.
