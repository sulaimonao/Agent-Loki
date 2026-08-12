# Agent Loki v1 provenance

Agent Loki v1 was derived from the committed history of a prior public Agent
Loki v0.5 source release. It was not created from scratch.

## Derivation record

- Source repository: prior public Agent Loki v0.5 repository
- Source branch: `main`
- Source commit: `4f279b3a6b54afcf81faf5fc018955b77a2fc159`
- Derivation date: 2026-07-15
- Derivation method: `git clone --no-hardlinks`

The committed source history was preserved in the private development
repository. Git object storage was independent from the source clone. The v0.5
source tree did not contain a tracked license or notice file at derivation
time.

## Public-release boundary

The private development history contains internal proof records, private-path
evidence, deleted message-shaped fixtures, and other material that is not part
of the public release. It must not be made public by changing repository
visibility or publishing the existing Git history.

The approved publication vehicle is either:

1. a source archive produced from a reviewed release commit; or
2. a clean-history export/new public repository initialized from that same
   sanitized source tree.

Both routes preserve this provenance record while excluding internal session
logs, credentials, user data, generated artifacts, and private operator paths.
The release scripts verify the candidate tree and refuse known private artifact
classes; reviewers must still inspect the resulting archive before upload.

## Protected and excluded material

Legacy private application data, environment files, databases, messages,
exports, checkpoints, credentials, signing assets, and generated output were
not migration sources for Agent Loki v1 and are not release content.

Project-owned source in this candidate is offered under the Apache License 2.0.
Third-party components retain their own licenses; see
[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).

## Release authorship and license decision

The release provenance review confirms that the inherited tree supplied no
prior license and that Agent Loki contributors selected Apache License 2.0 for
the project-owned source in this candidate. `LICENSE` and `NOTICE` record that
release decision, so inherited-source relicensing is not an open local
source-RC blocker.

The release provenance review also classifies the approved icon masters and
generated AppIcon renditions as project artwork contributed to Agent Loki and
distributed with this Apache-2.0 source candidate; no separate artwork or
trademark reservation is declared here.

Git metadata is provenance evidence, not an independent legal opinion. Before
public upload, the maintainer still confirms that the exact final tree adds no
third-party source or artwork outside this authority and that all dependency
licenses and notices are preserved. That human publication check does not
reopen the resolved local license selection.
