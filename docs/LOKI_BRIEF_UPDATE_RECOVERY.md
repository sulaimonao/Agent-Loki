# Loki Brief Update and Chat Recovery

Status: private P7 recovery contract. This document does not authorize an
update-host publication, application release, downgrade, public distribution,
or destructive recovery.

## Recovery invariant

Loki Brief must preserve truthful local state across an update attempt,
application termination, and relaunch. The secure-update coordinator owns
install admission. Agent Loki Chat participates in that admission; it never
installs an update, changes the selected update channel, or bypasses another
participant.

Before an update installation may proceed, Loki Brief:

1. rejects new chat requests and new read-only tool requests;
2. requires active chat generation and tool work to finish or be canceled;
3. invalidates late model and tool callbacks;
4. persists only truthful visible message state and bounded receipts;
5. saves and quiesces SwiftData, then closes the logical chat-persistence
   access boundary until termination or recovery;
6. checkpoints and closes Loki Vault SQLite;
7. retains the mutation barrier through the install handoff.

An active chat stream, model assessment, or local tool request is an explicit
readiness blocker. Update installation must not race those operations or
silently discard them.

The Agent Loki generation controller and read-only tool executor use separate
admission and cancellation epochs. The combined application readiness view must
include both active counts. Vault-backed tools also enter the existing Vault
foreground-operation barrier, so an active search/item read cannot disappear
from update readiness merely because it originated in chat.

## Interrupted chat reconciliation

On relaunch, a message left in a transient waiting, streaming, or tool state is
reconciled to an interrupted terminal state with a stable reason code. Any
truthful user-visible partial answer may remain. Hidden reasoning, provider
buffers, raw tool results, and incomplete source context are not recovered or
persisted.

The user may explicitly retry an interrupted request. Loki Brief never
automatically retries a tool-using request, because source authorization,
selection, evidence, and provider state may have changed.

## Aborted installation

If installation is canceled or readiness preparation fails, recovery occurs in
reverse preparation order:

- Loki Vault reopens and is checked before archive-backed chat tools resume;
- SwiftData remains the authoritative local conversation store; its logical
  chat-persistence access boundary reopens before conversation admission;
- chat and tool admission reopen only after every required participant reports
  recovery;
- a late completion from the pre-update epoch remains invalid and cannot create
  a conversation, message, evidence reference, or tool receipt.

If a required store cannot reopen, Loki Brief reports a degraded state and
keeps affected chat/tool operations unavailable. It does not reset or recreate
the store.

An aborted install does not automatically retry an assessment, generation, or
tool-using request. The user may retry only after provider readiness,
authorization, source consent, and store availability are reevaluated.

## Delete All interaction

Delete All Local Data and update installation are mutually exclusive. Delete
All cancels Agent Loki generation and tools, drains their bounded tasks,
invalidates callbacks, and then deletes conversations, messages, context
selections, answer attribution, evidence references, tool receipts, generation
provenance, chat policies, and model assessments.

Delete All does not stop Ollama, delete installed models, remove external
provider data, or publish any remote deletion. It must leave no conversation or
assessment recreated by the same operation.

## Operator recovery

For an update failure:

1. preserve the existing sandbox container, Keychain items, and Loki Vault
   files;
2. preserve privacy-safe structured diagnostics and the signed-update receipt;
3. verify the installed app version/build and the last terminal update/chat
   reason codes;
4. relaunch only a reviewed signed and storage-compatible build;
5. verify conversation history, brief history, schedules, source state, Vault,
   and credentials without exposing their content in logs.

Reinstalling or replacing the app bundle is not evidence that a storage
downgrade is safe. Never clear the sandbox container, SwiftData store, Vault,
or Keychain as an ordinary update-recovery step.

## Verification

Deterministic proof covers active generation and active tool blockers,
cancellation drain, admission closure, late-result rejection, truthful partial
message persistence, interrupted-state reconciliation, balanced Vault
foreground reads, closure and reopening of the logical chat-persistence access
boundary around the process-owned SwiftData container, Vault reopen, and
admission recovery after an aborted install.

Manual proof must also:

1. start a disposable streamed response and a registered read-only tool;
2. request update readiness and confirm both operations are visible blockers;
3. cancel/drain without accepting a late success;
4. cancel installation before handoff;
5. confirm Vault and chat persistence reopen before new work is accepted;
6. reopen the conversation and verify only truthful visible state and bounded
   receipts remain;
7. inspect traces for linked state/reason evidence without prompt, answer,
   source, credential, path, raw-model, or hidden-reasoning content.

## Scope boundary

P7 adds only local chat/update cooperation. It does not add automatic rollback,
cloud backup, remote recovery, a production update host, or a public release.
The exact deferred order remains P8 embeddings/semantic retrieval/explicit
memory/web research; P9 Workbench journal/goals/projects/tasks; P10 additional
connectors; P11 verified external writes; and P12 commercial tier.
