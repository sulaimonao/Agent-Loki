#!/bin/sh
set -eu

preflight_only=false
case "${1-}" in
  "") ;;
  --preflight-only) preflight_only=true ;;
  *)
    echo "usage: scripts/run-disposable-app-smoke.sh [--preflight-only]" >&2
    exit 2
    ;;
esac

smoke_script_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P) || exit 2
smoke_root_dir=$(dirname "$smoke_script_dir")
cd "$smoke_root_dir"

smoke_tmp_base=${TMPDIR:-/tmp}
smoke_tmp_base=${smoke_tmp_base%/}
smoke_work_root=$(mktemp -d "$smoke_tmp_base/agent-loki-disposable-smoke.XXXXXX")

cleanup() {
  case "$smoke_work_root" in
    "$smoke_tmp_base"/agent-loki-disposable-smoke.*)
      rm -rf "$smoke_work_root"
      echo "run-disposable-app-smoke: cleanup=complete"
      ;;
    *)
      echo "run-disposable-app-smoke: refusing unsafe cleanup target" >&2
      ;;
  esac
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

case "$smoke_work_root/" in
  "$smoke_root_dir/"*)
    echo "run-disposable-app-smoke: temporary root must be outside the repository" >&2
    exit 2
    ;;
esac

mkdir -p "$smoke_work_root/tmp" "$smoke_work_root/DerivedData"

# Each entry is target class, exact method, and its defining source. Keeping the
# source path explicit makes a renamed, deleted, or silently disabled smoke hook
# a deterministic preflight failure instead of an accidental test omission.
smoke_failed=0
set --
while IFS='|' read -r smoke_class smoke_method smoke_source; do
  if [ ! -f "$smoke_source" ]; then
    echo "run-disposable-app-smoke: missing named test source: $smoke_source" >&2
    smoke_failed=1
    continue
  fi
  if ! grep -F "class $smoke_class" "$smoke_source" >/dev/null; then
    echo "run-disposable-app-smoke: missing named test class: $smoke_class ($smoke_source)" >&2
    smoke_failed=1
    continue
  fi
  if ! grep -E "^[[:space:]]*func[[:space:]]+$smoke_method[[:space:]]*\(" "$smoke_source" >/dev/null; then
    echo "run-disposable-app-smoke: missing named test method: $smoke_class/$smoke_method ($smoke_source)" >&2
    smoke_failed=1
    continue
  fi
  set -- "$@" "-only-testing:LokiBriefTests/$smoke_class/$smoke_method"
done <<'EOF'
LokiBriefReleaseSmokeTests|testFirstLaunchOnboardingAndSourceListUseDisposableState|macos/LokiBrief/LokiBriefTests/LokiBriefReleaseSmokeTests.swift
AttachedDataSourcesControllerTests|testLinkedSQLiteCommitSurvivesRestartAndCarriesProvenanceSearchAndConsent|macos/LokiBrief/LokiBriefTests/AttachedDataSourcesControllerTests.swift
AttachedDataSourcesControllerTests|testJSONSnapshotPreviewSelectionAndModeCommitWithoutRetainedBookmark|macos/LokiBrief/LokiBriefTests/AttachedDataSourcesControllerTests.swift
AttachedDataSourcesControllerTests|testJSONLinkedReadOnlyRetainsBookmarkAndRefreshesEditedFileWithoutMutation|macos/LokiBrief/LokiBriefTests/AttachedDataSourcesControllerTests.swift
AttachedDataSourcesControllerTests|testSQLiteSnapshotDropsBookmarkRejectsRefreshAndPreservesVaultProvenance|macos/LokiBrief/LokiBriefTests/AttachedDataSourcesControllerTests.swift
AttachedDataSourcesControllerTests|testDuplicateRefreshIsIdempotentThenEditAndDeleteReconcileRevisionAndTombstone|macos/LokiBrief/LokiBriefTests/AttachedDataSourcesControllerTests.swift
AttachedDataSourcesControllerTests|testReplacementFailureRetainsGenerationUntilExplicitReauthorization|macos/LokiBrief/LokiBriefTests/AttachedDataSourcesControllerTests.swift
AttachedDataSourcesControllerTests|testCancellationDuringRefreshRetainsGenerationAndBalancesFileAuthority|macos/LokiBrief/LokiBriefTests/AttachedDataSourcesControllerTests.swift
AttachedDataSourcesControllerTests|testCancelledFirstImportCanRetryWithoutPriorGenerationAuthority|macos/LokiBrief/LokiBriefTests/AttachedDataSourcesControllerTests.swift
AttachedDataSourcesControllerTests|testRestartRestoresRetainedGenerationAuthorityWithoutSuccessReceipt|macos/LokiBrief/LokiBriefTests/AttachedDataSourcesControllerTests.swift
AttachedDataSourcesControllerTests|testDetachPreservesLocalDataUntilSeparateRemoval|macos/LokiBrief/LokiBriefTests/AttachedDataSourcesControllerTests.swift
AgentLokiReadOnlyToolTests|testAttachedSourceAuthorityPinsAAndDeniesB|macos/LokiBrief/LokiBriefTests/AgentLokiReadOnlyToolTests.swift
AgentLokiReadOnlyToolTests|testAttachedSourceAuthorityRevalidatesAfterRead|macos/LokiBrief/LokiBriefTests/AgentLokiReadOnlyToolTests.swift
AgentLokiContextBuilderTests|testSelectedContextScopesExposeOnlyTheirReadOnlyToolPlane|macos/LokiBrief/LokiBriefTests/AgentLokiContextBuilderTests.swift
LokiChatPresentationTests|testReadinessGatesSendingUntilAssessmentIsReady|macos/LokiBrief/LokiBriefTests/LokiChatPresentationTests.swift
LokiChatControllerLifecycleTests|testConnectedSourceContextPersistsExactAttachedSourceIdentifier|macos/LokiBrief/LokiBriefTests/LokiChatControllerLifecycleTests.swift
LokiChatControllerLifecycleTests|testAgentAttachedJSONCitationUsesExactRecordPointer|macos/LokiBrief/LokiBriefTests/LokiChatControllerLifecycleTests.swift
LokiChatControllerLifecycleTests|testLiveDataSourceRequiresPersistedAttachedSourceConsentRetentionAndContainerSelection|macos/LokiBrief/LokiBriefTests/LokiChatControllerLifecycleTests.swift
LokiChatControllerLifecycleTests|testLiveDataSourceRejectsQuarantinedAttachedAuthorityWithoutDigests|macos/LokiBrief/LokiBriefTests/LokiChatControllerLifecycleTests.swift
VaultDatabaseTests|testAttachedSearchProjectsSQLiteRowAndJSONPointerProvenanceWithoutRawMetadata|macos/LokiBrief/LokiBriefTests/VaultDatabaseTests.swift
LokiChatControllerLifecycleTests|testExternalEvidenceDeletionPurgesDerivedSemanticRowsBeforeChatResumes|macos/LokiBrief/LokiBriefTests/LokiChatControllerLifecycleTests.swift
P8FeatureControllerTests|testSemanticSourcePurgeFailsClosedImmediatelyAndDeletesDerivedRows|macos/LokiBrief/LokiBriefTests/P8FeatureControllerTests.swift
P6ReleasePolicyTests|testFreshInstallDefaultsContainNoLiveFixtureOrBackgroundOptIn|macos/LokiBrief/LokiBriefTests/P6ReleasePolicyTests.swift
ConnectorSourcesControllerTests|testLaunchRequiresExplicitResumeWithoutClaimingConnected|macos/LokiBrief/LokiBriefTests/ConnectorSourcesControllerTests.swift
SlackAppControllerTests|testLaunchLoadsOnlyNonsecretMetadataWithoutKeychainBrowserOrNetwork|macos/LokiBrief/LokiBriefTests/SlackAppControllerTests.swift
DeterministicSlackBriefingP3Tests|testMixedEngineUsesStableGlobalOrderAndPreservesSlackAttribution|macos/LokiBrief/LokiBriefTests/DeterministicSlackBriefingP3Tests.swift
SlackAPIClientP3Tests|testCancellationStopsActiveTransportAndNoWriteMethodExists|macos/LokiBrief/LokiBriefTests/SlackIngestionP3Tests.swift
SlackAppControllerTests|testDisconnectRevokesAndDeletesCredentialWhilePreservingWorkspaceData|macos/LokiBrief/LokiBriefTests/SlackAppControllerTests.swift
DiscordConnectorTests|testThreadHistoryPaginationProducesStableProvenanceAndIndexHandoffs|macos/LokiBrief/LokiBriefTests/DiscordConnectorTests.swift
DiscordConnectorTests|testCancellationStopsActiveTransportAndUsesStableReasonCode|macos/LokiBrief/LokiBriefTests/DiscordConnectorTests.swift
DiscordConnectorTests|testDisconnectDeletesCredentialWithoutRemoteMutationOrLocalDataDeletion|macos/LokiBrief/LokiBriefTests/DiscordConnectorTests.swift
EmailImportControllerTests|testSyntheticEMLProducesDeterministicVaultReadyImportResult|macos/LokiBrief/LokiBriefTests/EmailImportControllerTests.swift
EmailImportControllerTests|testMBoxPaginationReceiptsAdvanceAndAppendStartsNewDeterministicRun|macos/LokiBrief/LokiBriefTests/EmailImportControllerTests.swift
EmailImportControllerTests|testCancellationDoesNotPublishHalfPreparedPage|macos/LokiBrief/LokiBriefTests/EmailImportControllerTests.swift
VaultSearchRetentionExportTests|testSearchComposesAllFiltersAndUsesDeterministicPagination|macos/LokiBrief/LokiBriefTests/VaultSearchRetentionExportTests.swift
LokiBriefPersistenceTests|testPersistenceClosesAndReopensOnDisk|macos/LokiBrief/LokiBriefTests/LokiBriefTests.swift
ConnectorPersistenceTests|testConnectorStatusReceiptAndEmailAccessRoundTripAndDelete|macos/LokiBrief/LokiBriefTests/ConnectorPersistenceTests.swift
ConnectorSourcesControllerTests|testRemoveLocalDataDeletesPreviouslySelectedContainersOnlyAfterConfirmationPath|macos/LokiBrief/LokiBriefTests/ConnectorSourcesControllerTests.swift
ConnectorSourcesControllerTests|testEmailAuthorizationRemovalPreservesAdmittedLocalData|macos/LokiBrief/LokiBriefTests/ConnectorSourcesControllerTests.swift
LokiBriefDomainTests|testUnavailableRenderingModelIsExplicit|macos/LokiBrief/LokiBriefTests/LokiBriefTests.swift
UpdateDomainTests|testStateMachineCoversOfflineFeedUnavailableAndRetry|macos/LokiBrief/LokiBriefTests/UpdateDomainTests.swift
EOF

attached_view_source=macos/LokiBrief/LokiBrief/AttachedDataSourcesViews.swift
for attached_literal in \
  'Button("Add Data Source…"' \
  'Text("Link Read-Only")' \
  'Text("Import into Vault")' \
  'Button("Detach…"' \
  'Button("Remove Local Data…"'
do
  if ! grep -F "$attached_literal" "$attached_view_source" >/dev/null; then
    echo "run-disposable-app-smoke: missing attached-data UI contract: $attached_literal" >&2
    smoke_failed=1
  fi
done

about_source=macos/LokiBrief/LokiBrief/Views.swift
for about_literal in \
  'About Agent Loki' \
  'Agent Loki V1.0.0 Release Candidate 3' \
  'Source release: v1.0.0-rc.3. Native bundle: 1.0.0 (3).' \
  'Licensed under Apache License 2.0.'
do
  if ! grep -F "$about_literal" "$about_source" >/dev/null; then
    echo "run-disposable-app-smoke: missing About/version/license assertion: $about_literal" >&2
    smoke_failed=1
  fi
done

if [ "$smoke_failed" -ne 0 ]; then
  exit 1
fi

echo "run-disposable-app-smoke: named-test and About metadata preflight passed"
if [ "$preflight_only" = true ]; then
  echo "run-disposable-app-smoke: execution=not-requested"
  exit 0
fi

command -v xcodebuild >/dev/null 2>&1 || {
  echo "run-disposable-app-smoke: xcodebuild is required" >&2
  exit 2
}

# Force fixture-only behavior. The selected methods use synthetic transports or
# local files, and package resolution is disabled below so an absent dependency
# fails closed instead of contacting a package server.
export TMPDIR="$smoke_work_root/tmp"
export LOKI_BRIEF_ISOLATED_TEST_DATA_ROOT="$smoke_work_root/store"
export LOKI_LIVE_OLLAMA=0
export LOKI_P7_LIVE_OLLAMA=0
export LOKI_P8_LIVE_OLLAMA=0
export LOKI_P8E_LIVE_OLLAMA=0
export LOKI_LIVE_FEED_URL=
export ENABLE_ENFORCEMENT=false
unset LOKI_LIVE_OLLAMA_MODEL
unset LOKI_P7_LIVE_OLLAMA_MODEL
unset LOKI_P7_LIVE_RETAIN_ROOT
unset LOKI_P8_GEMMA4_MODEL
unset LOKI_P8_GPT_OSS_MODEL
unset LOKI_P8E_METRICS_PATH
unset LOKI_P6U_LIVE_FIXTURE_PHASE
unset LOKI_P6U_LIVE_FIXTURE_NAMESPACE

echo "run-disposable-app-smoke: root=task-owned-temporary; live-network=disabled; installed-app=untouched"
xcodebuild \
  -project macos/LokiBrief/LokiBrief.xcodeproj \
  -scheme LokiBrief \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$smoke_work_root/DerivedData" \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile \
  -skipPackageUpdates \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  DEVELOPMENT_TEAM= \
  CODE_SIGN_IDENTITY= \
  -parallel-testing-enabled NO \
  "$@" \
  test

echo "run-disposable-app-smoke: passed"
