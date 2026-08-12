#!/bin/bash
set -euo pipefail

RELEASE_PROGRAM=prepare-github-release
release_script_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P)
# shellcheck source=release-common.sh
source "$release_script_dir/release-common.sh"

usage() {
  cat >&2 <<'USAGE'
usage: scripts/prepare-github-release.sh --tag TAG --artifact-root ABSOLUTE_DIR \
  --canonical-repo ABSOLUTE_DIR --publication-repo ABSOLUTE_DIR \
  --publication-author-name PUBLIC_NAME --publication-author-email PUBLIC_EMAIL \
  --github-repository OWNER/REPO [--expected-origin HTTPS_GITHUB_URL] \
  --source-archive ABSOLUTE_FILE \
  --sbom ABSOLUTE_FILE --release-notes ABSOLUTE_FILE --verification ABSOLUTE_FILE \
  --candidate-verification-record ABSOLUTE_JSON \
  --binary-status STATUS [--team-id TEAM_ID --certificate-fingerprint SHA1 \
  --dmg ABSOLUTE_FILE \
  --signing-record ABSOLUTE_JSON --notarization-record ABSOLUTE_JSON \
  --dmg-verification ABSOLUTE_JSON --install-smoke-record ABSOLUTE_JSON] \
  [--inspection-dmg ABSOLUTE_FILE] [--dry-run]

STATUS is BINARY_DISTRIBUTION_READY, BINARY_DISTRIBUTION_PENDING_SIGNING, or a
BINARY_DISTRIBUTION_BLOCKED_* reason. READY requires a schema-valid disposable
install-smoke record bound to the tag, publication tree, DMG digest, copied app,
first launch, relaunch, About version/build, SQLite and JSON fixture flows, quit,
and cleanup. The outer PUBLICATION_PACKET.json is a local control receipt and is
not an upload. A local command plan and publication checklist record every
operator-reserved GitHub setting and publication action. This command never
creates a repository, adds a remote, pushes, creates a release, or uploads.
USAGE
}

release_tag=
artifact_root_input=
canonical_repo_input=
publication_repo_input=
publication_author_name=
publication_author_email=
github_repository=
expected_origin=
source_archive_input=
sbom_input=
release_notes_input=
verification_input=
candidate_verification_input=
binary_status=
expected_team=
expected_fingerprint=
dmg_input=
signing_record_input=
notarization_record_input=
dmg_verification_input=
install_smoke_record_input=
inspection_dmg_input=
dry_run=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag|--artifact-root|--canonical-repo|--publication-repo|--publication-author-name|--publication-author-email|--github-repository|--expected-origin|--source-archive|--sbom|--release-notes|--verification|--candidate-verification-record|--binary-status|--team-id|--certificate-fingerprint|--dmg|--signing-record|--notarization-record|--dmg-verification|--install-smoke-record|--inspection-dmg)
      release_require_value "$1" "${2-}"
      case "$1" in
        --tag) release_tag=$2 ;;
        --artifact-root) artifact_root_input=$2 ;;
        --canonical-repo) canonical_repo_input=$2 ;;
        --publication-repo) publication_repo_input=$2 ;;
        --publication-author-name) publication_author_name=$2 ;;
        --publication-author-email) publication_author_email=$2 ;;
        --github-repository) github_repository=$2 ;;
        --expected-origin) expected_origin=$2 ;;
        --source-archive) source_archive_input=$2 ;;
        --sbom) sbom_input=$2 ;;
        --release-notes) release_notes_input=$2 ;;
        --verification) verification_input=$2 ;;
        --candidate-verification-record) candidate_verification_input=$2 ;;
        --binary-status) binary_status=$2 ;;
        --team-id) expected_team=$2 ;;
        --certificate-fingerprint) expected_fingerprint=$2 ;;
        --dmg) dmg_input=$2 ;;
        --signing-record) signing_record_input=$2 ;;
        --notarization-record) notarization_record_input=$2 ;;
        --dmg-verification) dmg_verification_input=$2 ;;
        --install-smoke-record) install_smoke_record_input=$2 ;;
        --inspection-dmg) inspection_dmg_input=$2 ;;
      esac
      shift 2
      ;;
    --dry-run)
      dry_run=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage
      release_usage_error "unknown argument: $1"
      ;;
  esac
done

for required_value in release_tag artifact_root_input canonical_repo_input publication_repo_input publication_author_name publication_author_email github_repository source_archive_input sbom_input release_notes_input verification_input candidate_verification_input binary_status; do
  [[ -n "${!required_value}" ]] || {
    usage
    release_usage_error "missing required input: $required_value"
  }
done
release_validate_text "publication author name" "$publication_author_name"
release_validate_text "publication author email" "$publication_author_email"
[[ "$github_repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
  release_usage_error "--github-repository must be OWNER/REPO"
expected_github_origin="https://github.com/${github_repository}.git"
if [[ -n "$expected_origin" && "$expected_origin" != "$expected_github_origin" ]]; then
  release_usage_error "--expected-origin must exactly match the HTTPS URL for --github-repository"
fi
case "$binary_status" in
  BINARY_DISTRIBUTION_READY|BINARY_DISTRIBUTION_PENDING_SIGNING) ;;
  *)
    [[ "$binary_status" =~ ^BINARY_DISTRIBUTION_BLOCKED_[A-Z0-9]+(_[A-Z0-9]+)*$ ]] ||
      release_usage_error "unsupported binary status: $binary_status"
    ;;
esac

release_root=$(release_repository_root_from_script "$release_script_dir")
canonical_repo=$(release_resolve_existing_directory "$canonical_repo_input")
publication_repo=$(release_resolve_existing_directory "$publication_repo_input")
[[ "$release_root" == "$canonical_repo" ]] ||
  release_usage_error "prepare-github-release must run from --canonical-repo"
artifact_root=$(release_resolve_existing_directory "$artifact_root_input")
release_assert_artifact_root "$canonical_repo" "$artifact_root"
release_assert_repo_clean_tag "$canonical_repo" "$release_tag"
release_assert_release_metadata "$canonical_repo" "$release_tag"
release_assert_repo_clean_tag "$publication_repo" "$release_tag"
release_assert_release_metadata "$publication_repo" "$release_tag"

canonical_commit=$(git -C "$canonical_repo" rev-parse "refs/tags/$release_tag^{commit}")
canonical_tree=$(git -C "$canonical_repo" rev-parse "refs/tags/$release_tag^{tree}")
canonical_tag_object=$(git -C "$canonical_repo" rev-parse "refs/tags/$release_tag")
publication_commit=$(git -C "$publication_repo" rev-parse "refs/tags/$release_tag^{commit}")
publication_tree=$(git -C "$publication_repo" rev-parse "refs/tags/$release_tag^{tree}")
publication_tag_object=$(git -C "$publication_repo" rev-parse "refs/tags/$release_tag")
publication_main_commit=$(git -C "$publication_repo" rev-parse refs/heads/main)
[[ "$canonical_tree" == "$publication_tree" ]] ||
  release_die "publication tagged tree differs from the canonical tagged tree"
[[ "$publication_main_commit" == "$publication_commit" ]] ||
  release_die "publication main does not point to the release tag commit"

asset_prefix=$(release_asset_prefix "$release_tag")
source_archive=$(release_assert_direct_child_file "$artifact_root" "$source_archive_input")
sbom=$(release_assert_direct_child_file "$artifact_root" "$sbom_input")
release_notes=$(release_assert_direct_child_file "$artifact_root" "$release_notes_input")
verification=$(release_assert_direct_child_file "$artifact_root" "$verification_input")
candidate_verification=$(release_assert_direct_child_file "$artifact_root" "$candidate_verification_input")
release_assert_expected_basename "$source_archive" "${asset_prefix}-source.tar.gz"
release_assert_expected_basename "$sbom" "${asset_prefix}-SBOM.spdx.json"
release_assert_expected_basename "$release_notes" "${asset_prefix}-RELEASE_NOTES.md"
release_assert_expected_basename "$verification" "${asset_prefix}-VERIFICATION.md"
release_assert_expected_basename "$candidate_verification" "${asset_prefix}-CANDIDATE_VERIFICATION.json"

publication_record="$artifact_root/${asset_prefix}-PUBLICATION_REPO_VERIFICATION.json"
manifest="$artifact_root/${asset_prefix}-RELEASE_MANIFEST.json"
checksums="$artifact_root/${asset_prefix}-SHA256SUMS.txt"
publication_plan="$artifact_root/${asset_prefix}-GITHUB_PUBLICATION_DRY_RUN.txt"
publication_checklist="$artifact_root/${asset_prefix}-GITHUB_PUBLICATION_CHECKLIST.md"
publication_packet="$artifact_root/${asset_prefix}-PUBLICATION_PACKET.json"
for new_output in "$publication_record" "$manifest" "$checksums" "$publication_plan" "$publication_checklist" "$publication_packet"; do
  release_assert_output_absent "$new_output"
done

manifest_inputs=
temporary_manifest=
checksum_reproduction=
packet_inputs=
temporary_packet=
source_archive_tar=
preparation_complete=false
cleanup_preparation_work() {
  local temporary
  for temporary in "$manifest_inputs" "$temporary_manifest" "$checksum_reproduction" "$packet_inputs" "$temporary_packet" "$source_archive_tar"; do
    [[ -z "$temporary" ]] || rm -f "$temporary"
  done
  if [[ "$preparation_complete" != true ]]; then
    for temporary in "$publication_record" "$manifest" "$checksums" "$publication_plan" "$publication_checklist" "$publication_packet"; do
      [[ ! -e "$temporary" && ! -L "$temporary" ]] || rm -f "$temporary"
    done
  fi
}
trap cleanup_preparation_work EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

payloads=("$source_archive" "$sbom" "$release_notes" "$verification" "$candidate_verification")
public_uploads=("$source_archive" "$sbom" "$release_notes" "$verification" "$candidate_verification")
inspection_dmg=
dmg=
signing_record=
notarization_record=
dmg_verification=
install_smoke_record=

if [[ "$binary_status" == BINARY_DISTRIBUTION_READY ]]; then
  [[ -n "$expected_team" && -n "$expected_fingerprint" && -n "$dmg_input" && -n "$signing_record_input" &&
     -n "$notarization_record_input" && -n "$dmg_verification_input" &&
     -n "$install_smoke_record_input" ]] ||
    release_usage_error "ready binary status requires --team-id, --certificate-fingerprint, --dmg, all three binary records, and --install-smoke-record"
  [[ "$expected_team" =~ ^[A-Z0-9]{10}$ ]] || release_usage_error "Team ID must be 10 uppercase letters or digits"
  release_validate_certificate_fingerprint "$expected_fingerprint"
  [[ -z "$inspection_dmg_input" ]] || release_usage_error "ready status cannot include an unsigned inspection DMG"
  dmg=$(release_assert_direct_child_file "$artifact_root" "$dmg_input")
  signing_record=$(release_assert_direct_child_file "$artifact_root" "$signing_record_input")
  notarization_record=$(release_assert_direct_child_file "$artifact_root" "$notarization_record_input")
  dmg_verification=$(release_assert_direct_child_file "$artifact_root" "$dmg_verification_input")
  install_smoke_record=$(release_assert_direct_child_file "$artifact_root" "$install_smoke_record_input")
  release_assert_expected_basename "$dmg" "${asset_prefix}-macOS-universal.dmg"
  release_assert_expected_basename "$signing_record" "${asset_prefix}-CODE_SIGNING.json"
  release_assert_expected_basename "$notarization_record" "${asset_prefix}-NOTARIZATION.json"
  release_assert_expected_basename "$dmg_verification" "${asset_prefix}-DMG-VERIFICATION.json"
  release_assert_expected_basename "$install_smoke_record" "${asset_prefix}-INSTALL-SMOKE.json"
  payloads+=("$dmg" "$signing_record" "$notarization_record" "$dmg_verification" "$install_smoke_record")
  # Keep the detailed signing record in the local control packet. The DMG
  # necessarily exposes its Developer ID signature, but publishing a second
  # text copy of the signer's legal certificate common name is unnecessary.
  public_uploads+=("$dmg" "$notarization_record" "$dmg_verification" "$install_smoke_record")
else
  [[ -z "$dmg_input" && -z "$signing_record_input" && -z "$notarization_record_input" &&
     -z "$dmg_verification_input" && -z "$install_smoke_record_input" &&
     -z "$expected_team" && -z "$expected_fingerprint" ]] ||
    release_usage_error "a public DMG, Team ID, and binary readiness records are forbidden unless status is BINARY_DISTRIBUTION_READY"
  if [[ -n "$inspection_dmg_input" ]]; then
    inspection_dmg=$(release_assert_direct_child_file "$artifact_root" "$inspection_dmg_input")
    release_assert_expected_basename "$inspection_dmg" "$(release_unsigned_inspection_dmg_basename "$release_tag")"
    payloads+=("$inspection_dmg")
  fi
fi

for required_command in cmp git gzip id python3 shasum; do
  release_require_command "$required_command"
done

validated_input_payloads=("${payloads[@]}")
validated_input_digests=()
verification_digest=
for validated_input in "${validated_input_payloads[@]}"; do
  validated_digest=$(release_sha256 "$validated_input")
  validated_input_digests+=("$validated_digest")
  if [[ "$validated_input" == "$verification" ]]; then
    verification_digest=$validated_digest
  fi
done
[[ -n "$verification_digest" ]] || release_die "verification payload was not included in the validated inputs"

assert_validated_inputs_unchanged() {
  local index
  local resolved_input
  local current_digest
  for ((index = 0; index < ${#validated_input_payloads[@]}; index++)); do
    resolved_input=$(release_assert_direct_child_file "$artifact_root" "${validated_input_payloads[$index]}")
    [[ "$resolved_input" == "${validated_input_payloads[$index]}" ]] ||
      release_die "validated input path changed: $(basename "${validated_input_payloads[$index]}")"
    current_digest=$(release_sha256 "$resolved_input")
    [[ "$current_digest" == "${validated_input_digests[$index]}" ]] ||
      release_die "validated input bytes changed: $(basename "$resolved_input")"
  done
}

assert_release_refs_unchanged() {
  [[ "$(git -C "$canonical_repo" rev-parse "refs/tags/$release_tag")" == "$canonical_tag_object" &&
     "$(git -C "$canonical_repo" rev-parse "refs/tags/$release_tag^{commit}")" == "$canonical_commit" &&
     "$(git -C "$canonical_repo" rev-parse "refs/tags/$release_tag^{tree}")" == "$canonical_tree" ]] ||
    release_die "canonical annotated tag identity changed during preparation"
  [[ "$(git -C "$publication_repo" rev-parse "refs/tags/$release_tag")" == "$publication_tag_object" &&
     "$(git -C "$publication_repo" rev-parse "refs/tags/$release_tag^{commit}")" == "$publication_commit" &&
     "$(git -C "$publication_repo" rev-parse "refs/tags/$release_tag^{tree}")" == "$publication_tree" &&
     "$(git -C "$publication_repo" rev-parse refs/heads/main)" == "$publication_main_commit" ]] ||
    release_die "publication annotated tag or main identity changed during preparation"
}

gzip -t "$source_archive" || release_die "source archive is not a valid gzip stream"
source_archive_tar=$(mktemp "$artifact_root/.agent-loki-source-archive.XXXXXX")
gzip -dc "$source_archive" >"$source_archive_tar" ||
  release_die "unable to decompress the source archive"
archive_commit=$(git -C "$publication_repo" get-tar-commit-id \
  <"$source_archive_tar" 2>/dev/null) ||
  release_die "source archive does not contain a Git archive commit identity"
[[ "$archive_commit" == "$publication_commit" ]] ||
  release_die "source archive commit $archive_commit does not match publication tag commit $publication_commit"
git -C "$publication_repo" archive --format=tar --prefix="${asset_prefix}/" "$publication_commit" |
  cmp -s "$source_archive_tar" - ||
  release_die "source archive bytes do not reproduce from the clean publication tag"
rm -f "$source_archive_tar"
source_archive_tar=

release_version=$(release_version_from_tag "$release_tag")
release_marketing=$(release_marketing_version_from_tag "$release_tag")
release_build=$(release_project_build_number "$canonical_repo")
python3 - "$sbom" "$candidate_verification" "$release_tag" "$release_version" \
  "$canonical_commit" "$canonical_tag_object" "$publication_commit" \
  "$publication_tree" "$publication_tag_object" "$publication_main_commit" \
  "$(basename "$verification")" "$verification_digest" <<'PY'
import json
import re
import sys
from datetime import datetime

(sbom_path, candidate_path, tag, version, canonical_commit, canonical_tag_object,
 publication_commit, publication_tree, publication_tag_object,
 publication_main_commit, verification_file, verification_digest) = sys.argv[1:]

def load_object(path, label):
    try:
        with open(path, encoding="utf-8") as handle:
            value = json.load(handle)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise SystemExit(f"invalid {label} JSON: {error}")
    if not isinstance(value, dict):
        raise SystemExit(f"invalid {label}: root must be an object")
    return value

def require_exact(record, key, expected, label):
    actual = record.get(key)
    if type(actual) is not type(expected) or actual != expected:
        raise SystemExit(f"invalid {label}: {key} does not match")

sbom = load_object(sbom_path, "SBOM")
expected_namespace = f"https://spdx.org/spdxdocs/agent-loki-{tag}-{publication_commit}"
if sbom.get("spdxVersion") != "SPDX-2.3":
    raise SystemExit("invalid SBOM: spdxVersion must be SPDX-2.3")
if sbom.get("SPDXID") != "SPDXRef-DOCUMENT":
    raise SystemExit("invalid SBOM: document SPDXID must be SPDXRef-DOCUMENT")
if sbom.get("dataLicense") != "CC0-1.0":
    raise SystemExit("invalid SBOM: dataLicense must be CC0-1.0")
if sbom.get("documentNamespace") != expected_namespace:
    raise SystemExit("invalid SBOM: namespace is not bound to the publication tag commit")
if sbom.get("name") != f"Agent-Loki-{tag}-SBOM":
    raise SystemExit("invalid SBOM: document name does not match the tag")
if sbom.get("documentDescribes") != ["SPDXRef-Package-Agent-Loki"]:
    raise SystemExit("invalid SBOM: documentDescribes must identify the Agent Loki root package")
creation = sbom.get("creationInfo")
if not isinstance(creation, dict):
    raise SystemExit("invalid SBOM: creationInfo must be an object")
created = creation.get("created")
creators = creation.get("creators")
if not isinstance(created, str) or not created.endswith("Z"):
    raise SystemExit("invalid SBOM: creationInfo.created must be a UTC timestamp")
try:
    datetime.fromisoformat(created[:-1] + "+00:00")
except ValueError as error:
    raise SystemExit("invalid SBOM: creationInfo.created is not an ISO-8601 timestamp") from error
if not isinstance(creators, list) or not creators or not all(
    isinstance(creator, str) and creator for creator in creators
):
    raise SystemExit("invalid SBOM: creationInfo.creators must contain nonempty strings")
packages = sbom.get("packages")
if not isinstance(packages, list):
    raise SystemExit("invalid SBOM: packages must be an array")
package_ids = [item.get("SPDXID") for item in packages if isinstance(item, dict)]
if len(package_ids) != len(packages) or not all(isinstance(item, str) and item for item in package_ids):
    raise SystemExit("invalid SBOM: every package must have a nonempty SPDXID")
if len(package_ids) != len(set(package_ids)):
    raise SystemExit("invalid SBOM: package SPDXIDs must be unique")
root_packages = [item for item in packages if isinstance(item, dict) and item.get("SPDXID") == "SPDXRef-Package-Agent-Loki"]
if len(root_packages) != 1:
    raise SystemExit("invalid SBOM: exactly one Agent Loki root package is required")
root_package = root_packages[0]
if root_package.get("versionInfo") != version:
    raise SystemExit("invalid SBOM: root package version does not match the tag")
for key, expected_type in {
    "name": str,
    "downloadLocation": str,
    "filesAnalyzed": bool,
    "licenseConcluded": str,
    "licenseDeclared": str,
}.items():
    if type(root_package.get(key)) is not expected_type:
        raise SystemExit(f"invalid SBOM: root package {key} has the wrong type")
if root_package["name"] != "Agent Loki" or root_package["filesAnalyzed"] is not False:
    raise SystemExit("invalid SBOM: root package identity/filesAnalyzed do not match")
if not all(root_package[key] for key in ("downloadLocation", "licenseConcluded", "licenseDeclared")):
    raise SystemExit("invalid SBOM: root package required strings must be nonempty")
relationships = sbom.get("relationships")
if not isinstance(relationships, list):
    raise SystemExit("invalid SBOM: relationships must be an array")

candidate = load_object(candidate_path, "candidate verification record")
expected_candidate = {
    "schemaVersion": 1,
    "status": "verified-exact-release-candidate",
    "tag": tag,
    "version": version,
    "canonicalCommit": canonical_commit,
    "canonicalTagObject": canonical_tag_object,
    "publicationCommit": publication_commit,
    "publicationMainCommit": publication_main_commit,
    "publicationTree": publication_tree,
    "publicationTagObject": publication_tag_object,
    "treeEquivalent": True,
    "releaseVerifier": "passed",
    "nativeTests": "passed",
    "nodeTests": "passed",
    "universalBuild": "passed",
    "disposableSmoke": "passed",
    "verificationFile": verification_file,
    "verificationSha256": verification_digest,
}
for key, expected in expected_candidate.items():
    require_exact(candidate, key, expected, "candidate verification record")
PY

if [[ "$binary_status" == BINARY_DISTRIBUTION_READY ]]; then
  dmg_digest=$(release_sha256 "$dmg")
  python3 - "$signing_record" "$notarization_record" "$dmg_verification" \
    "$install_smoke_record" "$release_tag" "$release_version" "$release_marketing" \
    "$release_build" "$expected_team" "$expected_fingerprint" "$(basename "$dmg")" "$dmg_digest" \
    "$publication_tree" "$publication_tag_object" <<'PY'
import json
import re
import sys

(signing_path, notary_path, verification_path, install_path, tag, version,
 marketing, build, team, fingerprint, dmg_name, dmg_digest, publication_tree,
 publication_tag_object) = sys.argv[1:]

def load_object(path, label):
    try:
        with open(path, encoding="utf-8") as handle:
            value = json.load(handle)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise SystemExit(f"invalid {label} JSON: {error}")
    if not isinstance(value, dict):
        raise SystemExit(f"invalid {label}: root must be an object")
    return value

def require_exact(record, key, expected, label):
    actual = record.get(key)
    if type(actual) is not type(expected) or actual != expected:
        raise SystemExit(f"invalid {label}: {key} does not match")

signing = load_object(signing_path, "code-signing record")
for key, expected in {
    "schemaVersion": 1, "status": "developer-id-signed", "tag": tag,
    "version": version, "teamId": team,
    "certificateFingerprintSha1": fingerprint,
    "hardenedRuntime": True, "secureTimestamp": True,
    "designatedRequirementsValid": True, "exactCodeInventory": True,
    "exactEntitlements": True, "nestedCodeObjectCount": 5,
}.items():
    require_exact(signing, key, expected, "code-signing record")
code_objects = signing.get("codeObjects")
if not isinstance(code_objects, list) or len(code_objects) != 6:
    raise SystemExit("invalid code-signing record: exact six-object inventory is missing")

notary = load_object(notary_path, "notarization record")
for key, expected in {
    "schemaVersion": 1, "status": "Accepted", "tag": tag,
    "version": version, "dmg": dmg_name, "dmgSha256AfterStapling": dmg_digest,
    "certificateFingerprintSha1": fingerprint,
    "staplerValidated": True, "issueCount": 0,
}.items():
    require_exact(notary, key, expected, "notarization record")

verification = load_object(verification_path, "DMG verification record")
for key, expected in {
    "schemaVersion": 1, "status": "verified-for-public-distribution",
    "tag": tag, "version": version, "developerIdTeam": team,
    "certificateFingerprintSha1": fingerprint,
    "dmg": dmg_name, "sha256": dmg_digest, "gatekeeperAccepted": True,
    "hardenedRuntime": True, "notarizationTicketStapled": True,
    "applicationsLink": "/Applications",
}.items():
    require_exact(verification, key, expected, "DMG verification record")
if verification.get("architectures") != ["arm64", "x86_64"]:
    raise SystemExit("invalid DMG verification record: architectures do not match")

install = load_object(install_path, "install-smoke record")
for key, expected in {
    "schemaVersion": 2,
    "status": "verified-disposable-install-smoke",
    "tag": tag,
    "version": version,
    "publicationTree": publication_tree,
    "publicationTagObject": publication_tag_object,
    "dmgSha256": dmg_digest,
    "taskOwnedInstallRoot": True,
    "applicationCopiedFromDMG": True,
    "launchedCopiedApplication": True,
    "firstLaunch": "passed",
    "relaunch": "passed",
    "quit": "passed",
    "cleanup": "passed",
    "liveNetworkUsed": False,
    "productionStoreUsed": False,
    "productionApplicationUsed": False,
    "mountDetachedBeforeLaunch": True,
    "storageClassification": "xctest_isolated_disk",
    "storageReasonCode": "persistence_xctest_isolated_disk_selected",
    "swiftDataVaultPaired": True,
    "productionStoreHandleCount": 0,
    "productionPreferenceFilesChanged": 0,
    "externalNetworkConnectionCount": 0,
    "p8fSmokeCapability": "disabled",
}.items():
    require_exact(install, key, expected, "install-smoke record")
if install.get("about") != {
    "status": "passed", "marketingVersion": marketing, "build": build,
    "license": "Apache-2.0",
}:
    raise SystemExit("invalid install-smoke record: About version/build proof does not match")
if install.get("attachedDataFixtures") != {"sqlite": "passed", "json": "passed"}:
    raise SystemExit("invalid install-smoke record: attached SQLite/JSON fixture proof is incomplete")
if install.get("uiFlows") != {
    "onboarding": "passed",
    "sourcesConnections": "passed",
    "attachedDataSourcesUI": "passed",
    "sqliteLinkReadOnly": "passed",
    "sqliteBoundedRetrieval": "passed",
    "jsonImportSnapshot": "passed",
    "provenance": "passed",
    "cancellation": "passed",
    "disposablePersistence": "passed",
    "detach": "passed",
    "removeLocalData": "passed",
}:
    raise SystemExit("invalid install-smoke record: required UI flows are incomplete")
copied = install.get("copiedApplication")
if not isinstance(copied, dict):
    raise SystemExit("invalid install-smoke record: copiedApplication must be an object")
for key, expected in {
    "bundleIdentifier": "com.agentloki.LokiBrief",
    "marketingVersion": marketing,
    "build": build,
    "architectures": ["arm64", "x86_64"],
    "developerIdTeam": team,
    "signatureVerified": True,
    "gatekeeperAccepted": True,
}.items():
    require_exact(copied, key, expected, "install-smoke copied application")
if re.fullmatch(r"[0-9a-f]{64}", copied.get("executableSha256", "")) is None:
    raise SystemExit("invalid install-smoke record: copied executable digest is malformed")
mounted = install.get("mountedImage")
if not isinstance(mounted, dict):
    raise SystemExit("invalid install-smoke record: mountedImage must be an object")
for key, expected in {
    "topLevelEntries": ["Applications", "LokiBrief.app"],
    "applicationsLink": "/Applications",
    "readOnlyMount": True,
    "copiedAppMatched": True,
}.items():
    require_exact(mounted, key, expected, "install-smoke mounted image")
if re.fullmatch(r"[0-9a-f]{64}", mounted.get("manifestSha256", "")) is None:
    raise SystemExit("invalid install-smoke record: mounted-image manifest digest is malformed")
PY
fi

assert_validated_inputs_unchanged
assert_release_refs_unchanged

verify_publication_command=(
  "$release_script_dir/verify-publication-repo.sh"
  --tag "$release_tag"
  --canonical-repo "$canonical_repo"
  --publication-repo "$publication_repo"
  --publication-author-name "$publication_author_name"
  --publication-author-email "$publication_author_email"
  --output "$publication_record"
)
if [[ -n "$expected_origin" ]]; then
  verify_publication_command+=(--expected-origin "$expected_origin")
fi
if [[ "$dry_run" == true ]]; then
  "${verify_publication_command[@]}" --dry-run
  if [[ "$binary_status" == BINARY_DISTRIBUTION_READY ]]; then
    "$release_script_dir/verify-dmg.sh" --tag "$release_tag" --artifact-root "$artifact_root" --dmg "$dmg" --team-id "$expected_team" --certificate-fingerprint "$expected_fingerprint" --no-record --dry-run
  fi
  assert_validated_inputs_unchanged
  assert_release_refs_unchanged
  printf 'DRY-RUN: write local publication command plan and machine-readable release manifest\n'
  printf 'DRY-RUN: generate, reproduce, and verify %s\n' "$(basename "$checksums")"
  printf 'DRY-RUN: write local non-upload control receipt %s\n' "$(basename "$publication_packet")"
  printf 'DRY-RUN: write local operator checklist %s\n' "$(basename "$publication_checklist")"
  printf 'prepare-github-release: execution=not-requested; no remote action attempted\n'
  preparation_complete=true
  trap - EXIT HUP INT TERM
  exit 0
fi

"${verify_publication_command[@]}"
payloads+=("$publication_record")
public_uploads+=("$publication_record")
if [[ "$binary_status" == BINARY_DISTRIBUTION_READY ]]; then
  "$release_script_dir/verify-dmg.sh" --tag "$release_tag" --artifact-root "$artifact_root" --dmg "$dmg" --team-id "$expected_team" --certificate-fingerprint "$expected_fingerprint" --no-record
fi
assert_validated_inputs_unchanged
assert_release_refs_unchanged

python3 - "$publication_author_email" "$(id -un)" "${public_uploads[@]}" <<'PY'
import json
import pathlib
import re
import sys

public_email = sys.argv[1]
local_user = sys.argv[2]
paths = [pathlib.Path(value) for value in sys.argv[3:]]
text_suffixes = {".json", ".md", ".spdx", ".txt"}
findings = []

def record(path, classification):
    findings.append(f"{path.name}:{classification}")

def walk_json(value, path):
    sensitive_keys = {
        "apikey", "appspecificpassword", "credential", "credentials",
        "password", "privatekey", "secret", "token",
    }
    if isinstance(value, dict):
        for key, item in value.items():
            normalized = re.sub(r"[^a-z]", "", str(key).lower())
            if normalized in sensitive_keys and item not in (None, "", [], {}):
                record(path, "credential-like-field")
            walk_json(item, path)
    elif isinstance(value, list):
        for item in value:
            walk_json(item, path)

for path in paths:
    suffixes = {suffix.lower() for suffix in path.suffixes}
    if not suffixes.intersection(text_suffixes):
        continue
    text = path.read_text(encoding="utf-8")
    identity_text = re.sub(re.escape(public_email), "", text, flags=re.IGNORECASE)
    classifications = {
        "absolute-macos-user-path": r"/(?:Users)/[^/\s`\"<>]+(?:/|$)",
        "absolute-linux-user-path": r"/(?:home)/[^/\s`\"<>]+(?:/|$)",
        "absolute-windows-user-path": r"[A-Za-z]:[\\/]Users[\\/][^\\/\s`\"<>]+(?:[\\/]|$)",
        "email-address": r"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b",
        "private-key-material": r"-----BEGIN(?: [A-Z0-9]+)? PRIVATE KEY-----",
        "secret-token-shape": r"(?:xox[baprs]-[A-Za-z0-9-]{10,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}|sk_live_[0-9A-Za-z]{16,}|glpat-[0-9A-Za-z_-]{16,}|npm_[0-9A-Za-z]{20,})",
    }
    for classification, pattern in classifications.items():
        if re.search(pattern, identity_text, flags=re.IGNORECASE):
            record(path, classification)
    if len(local_user) >= 3 and re.search(
        rf"(?<![A-Za-z0-9]){re.escape(local_user)}(?![A-Za-z0-9])",
        identity_text,
        flags=re.IGNORECASE,
    ):
        record(path, "local-user-name")
    if ".json" in suffixes:
        walk_json(json.loads(text), path)

if findings:
    raise SystemExit("public upload privacy scan failed:\n" + "\n".join(sorted(set(findings))))
print(f"prepare-github-release: public-upload-privacy-scan=passed files={len(paths)}")
PY

release_candidate_number=${release_version##*.}
release_title="Agent Loki V$release_marketing Release Candidate $release_candidate_number"
source_status="AGENT_LOKI_V1_RC${release_candidate_number}_GITHUB_PUBLICATION_PREP_READY"
github_owner=${github_repository%%/*}
emit_publication_commands() {
  printf '%s\n' 'set -eu'
  printf '%s\n' 'if (set -o pipefail) 2>/dev/null; then set -o pipefail; fi'
  printf '%s\n' ': "${PUBLICATION_REPO:?set to the verified clean publication repository}"'
  printf '%s\n' ': "${ARTIFACT_ROOT:?set to the final release artifact directory}"'
  printf 'test "$(git -C "$PUBLICATION_REPO" rev-parse refs/heads/main)" = %q\n' "$publication_main_commit"
  printf 'test "$(git -C "$PUBLICATION_REPO" rev-parse refs/tags/%s)" = %q\n' "$release_tag" "$publication_tag_object"
  printf 'test "$(git -C "$PUBLICATION_REPO" rev-parse refs/tags/%s^{commit})" = %q\n' "$release_tag" "$publication_commit"
  printf 'gh auth status --hostname github.com\n'
  printf 'test "$(gh api user --jq .login)" = %q\n' "$github_owner"
  if [[ -z "$expected_origin" ]]; then
    printf 'if gh api repos/%s >/dev/null 2>&1; then echo %q >&2; exit 1; fi\n' \
      "$github_repository" "target repository already exists: $github_repository"
    printf 'gh repo create %s --public --description %q\n' "$github_repository" \
      'Local-first macOS knowledge and assistant app with Slack, Discord, email, SQLite, and JSON sources.'
    printf 'git -C "$PUBLICATION_REPO" remote add origin %s\n' "$expected_github_origin"
    printf 'git -C "$PUBLICATION_REPO" push origin %s:refs/heads/main\n' "$publication_main_commit"
    printf 'git -C "$PUBLICATION_REPO" push origin %s:refs/tags/%s\n' "$publication_tag_object" "$release_tag"
  else
    printf 'test "$(git -C "$PUBLICATION_REPO" remote)" = origin\n'
    printf 'test "$(git -C "$PUBLICATION_REPO" remote get-url origin)" = %q\n' "$expected_origin"
    printf 'test "$(git -C "$PUBLICATION_REPO" remote get-url --push origin)" = %q\n' "$expected_origin"
    printf 'test "$(gh api repos/%s --jq .visibility)" = public\n' "$github_repository"
  fi
  printf 'test "$(git -C "$PUBLICATION_REPO" ls-remote origin refs/heads/main | awk %q)" = %q\n' '{print $1}' "$publication_main_commit"
  printf 'test "$(git -C "$PUBLICATION_REPO" ls-remote origin refs/tags/%s | awk %q)" = %q\n' "$release_tag" '{print $1}' "$publication_tag_object"
  printf 'test "$(git -C "$PUBLICATION_REPO" ls-remote origin refs/tags/%s^{} | awk %q)" = %q\n' "$release_tag" '{print $1}' "$publication_commit"
  printf 'test "$(git -C "$PUBLICATION_REPO" ls-remote --heads --tags origin | wc -l | tr -d %q)" = 3\n' ' '
  printf 'test "$(gh api repos/%s/git/commits/%s --jq .tree.sha)" = %q\n' "$github_repository" "$publication_main_commit" "$publication_tree"
  printf 'gh api --method PATCH repos/%s -f default_branch=main\n' "$github_repository"
  printf 'gh api --method PATCH repos/%s -f description=%q\n' "$github_repository" \
    'Local-first macOS knowledge and assistant app with Slack, Discord, email, SQLite, and JSON sources.'
  printf 'gh api --method PUT repos/%s/actions/permissions -F enabled=true -f allowed_actions=all\n' "$github_repository"
  printf 'gh api --method PATCH repos/%s -F has_discussions=true\n' "$github_repository"
  printf 'gh api --method PUT repos/%s/private-vulnerability-reporting\n' "$github_repository"
  printf 'gh api --method PUT repos/%s/vulnerability-alerts\n' "$github_repository"
  printf 'gh api --method PUT repos/%s/automated-security-fixes\n' "$github_repository"
  printf 'gh api --method PUT repos/%s/branches/main/protection --input - <<%s\n' "$github_repository" "'BRANCH_PROTECTION_JSON'"
  printf '%s\n' \
    '{' \
    '  "required_status_checks": null,' \
    '  "enforce_admins": true,' \
    '  "required_pull_request_reviews": null,' \
    '  "restrictions": null,' \
    '  "required_linear_history": true,' \
    '  "allow_force_pushes": false,' \
    '  "allow_deletions": false,' \
    '  "block_creations": false,' \
    '  "required_conversation_resolution": true,' \
    '  "lock_branch": false,' \
    '  "allow_fork_syncing": true' \
    '}' \
    'BRANCH_PROTECTION_JSON'
  printf 'gh api repos/%s --jq %q\n' "$github_repository" '{visibility: .visibility, defaultBranch: .default_branch, discussions: .has_discussions}'
  printf 'gh api repos/%s/actions/permissions\n' "$github_repository"
  printf 'gh api repos/%s/private-vulnerability-reporting\n' "$github_repository"
  printf 'gh api repos/%s/branches/main/protection\n' "$github_repository"
  printf 'gh api repos/%s/vulnerability-alerts\n' "$github_repository"
  printf '%s\n' 'RUN_ID=' 'RUN_WAIT_ATTEMPT=0'
  printf '%s\n' 'while [ "$RUN_WAIT_ATTEMPT" -lt 90 ] && [ -z "$RUN_ID" ]; do'
  printf '  RUN_ID=$(gh run list --repo %s --commit %s --workflow fixture-ci.yml --limit 1 --json databaseId,headSha --jq %q)\n' \
    "$github_repository" "$publication_main_commit" '.[0].databaseId // empty'
  printf '%s\n' \
    '  [ -n "$RUN_ID" ] || sleep 10' \
    '  RUN_WAIT_ATTEMPT=$((RUN_WAIT_ATTEMPT + 1))' \
    'done' \
    'test -n "$RUN_ID"'
  printf 'gh run watch "$RUN_ID" --repo %s --exit-status\n' "$github_repository"
  printf 'test "$(gh run view "$RUN_ID" --repo %s --json headSha,status,conclusion --jq %q)" = %q\n' \
    "$github_repository" '[.headSha,.status,.conclusion] | join(" ")' "$publication_main_commit completed success"
  printf 'gh release create %s --repo %s --draft --prerelease --verify-tag --title %q --notes-file "$ARTIFACT_ROOT/%s"\n' \
    "$release_tag" "$github_repository" "$release_title" "$(basename "$release_notes")"
  printf 'gh release upload %s --repo %s' "$release_tag" "$github_repository"
  for upload in "${public_uploads[@]}" "$manifest" "$checksums"; do
    printf ' "$ARTIFACT_ROOT/%s"' "$(basename "$upload")"
  done
  printf '\n'
  printf '%s\n' 'DOWNLOAD_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/agent-loki-publication-download.XXXXXX")'
  printf 'gh release download %s --repo %s --dir "$DOWNLOAD_ROOT"\n' "$release_tag" "$github_repository"
  printf 'python3 - "$ARTIFACT_ROOT/%s" "$DOWNLOAD_ROOT" <<%s\n' "$(basename "$publication_packet")" "'VERIFY_DOWNLOADED_ASSETS_PY'"
  printf '%s\n' \
    'import hashlib' \
    'import json' \
    'import pathlib' \
    'import sys' \
    '' \
    'packet = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))' \
    'download_root = pathlib.Path(sys.argv[2])' \
    'expected = {item["name"]: item["sha256"] for item in packet["uploads"]}' \
    'actual = {item.name for item in download_root.iterdir() if item.is_file()}' \
    'if actual != set(expected):' \
    '    raise SystemExit("downloaded release asset names differ from PUBLICATION_PACKET.json")' \
    'for name, expected_digest in expected.items():' \
    '    digest = hashlib.sha256((download_root / name).read_bytes()).hexdigest()' \
    '    if digest != expected_digest:' \
    '        raise SystemExit(f"downloaded release asset digest differs: {name}")' \
    'print(f"verified downloaded release assets: {len(expected)}")' \
    'VERIFY_DOWNLOADED_ASSETS_PY'
  printf 'gh release edit %s --repo %s --draft=false --prerelease\n' "$release_tag" "$github_repository"
  printf 'test "$(gh release view %s --repo %s --json isDraft --jq .isDraft)" = false\n' "$release_tag" "$github_repository"
  printf 'test "$(gh release view %s --repo %s --json isPrerelease --jq .isPrerelease)" = true\n' "$release_tag" "$github_repository"
  printf 'test "$(gh release view %s --repo %s --json tagName --jq .tagName)" = %q\n' "$release_tag" "$github_repository" "$release_tag"
  printf 'test "$(gh release view %s --repo %s --json name --jq .name)" = %q\n' "$release_tag" "$github_repository" "$release_title"
  printf 'LATEST_TAG=$(gh api repos/%s/releases/latest --jq .tag_name 2>/dev/null || true)\n' "$github_repository"
  printf 'test "$LATEST_TAG" != %q\n' "$release_tag"
  printf 'gh release view %s --repo %s --json isDraft,isPrerelease,tagName,name,url,assets\n' "$release_tag" "$github_repository"
  printf 'test "$(GIT_TERMINAL_PROMPT=0 git -c credential.helper= ls-remote %s refs/heads/main | awk %q)" = %q\n' \
    "$expected_github_origin" '{print $1}' "$publication_main_commit"
  printf 'curl -fsSL https://api.github.com/repos/%s/releases/tags/%s | python3 -c %q %q\n' \
    "$github_repository" "$release_tag" \
    'import json,sys; value=json.load(sys.stdin); assert value["tag_name"] == sys.argv[1] and value["draft"] is False and value["prerelease"] is True' "$release_tag"
  if [[ "$binary_status" == BINARY_DISTRIBUTION_READY ]]; then
    printf 'curl -fsSIL https://github.com/%s/releases/download/%s/%s >/dev/null\n' \
      "$github_repository" "$release_tag" "$(basename "$dmg")"
  fi
  printf 'python3 - "$DOWNLOAD_ROOT" <<%s\n' "'CLEAN_DOWNLOADED_ASSETS_PY'"
  printf '%s\n' \
    'import pathlib' \
    'import shutil' \
    'import sys' \
    '' \
    'root = pathlib.Path(sys.argv[1]).resolve()' \
    'if not root.is_dir() or not root.name.startswith("agent-loki-publication-download."):' \
    '    raise SystemExit(f"refusing unsafe download cleanup: {root}")' \
    'shutil.rmtree(root)' \
    'CLEAN_DOWNLOADED_ASSETS_PY'
}

{
  printf '# LOCAL DRY-RUN PUBLICATION PLAN — DO NOT EXECUTE WITHOUT EXPLICIT PUBLICATION AUTHORITY\n'
  printf '# No command in this file was executed by prepare-github-release.sh.\n'
  printf '# Set the two task-owned local path variables, review each command, and execute only with separate authority.\n\n'
  emit_publication_commands
} >"$publication_plan"
chmod 0644 "$publication_plan"

{
  printf '# GitHub Publication Checklist — %s\n\n' "$release_tag"
  printf 'This local control file records operator-reserved actions. No command below was executed by release preparation.\n\n'
  printf -- '- [ ] Set `PUBLICATION_REPO` to the verified standalone clean-history repository.\n'
  printf -- '- [ ] Set `ARTIFACT_ROOT` to this final release-artifact directory.\n'
  printf -- '- [ ] Reproduce and verify every SHA256SUMS entry and the outer packet checksum digest.\n'
  printf -- '- [ ] Review the exact public repository, main ref, annotated tag object, and release asset inventory.\n'
  printf -- '- [ ] Execute the commands below only with explicit publication authority.\n\n'
  printf '```sh\n'
  emit_publication_commands
  printf '```\n\n'
  printf -- '- [ ] Confirm repository visibility is public.\n'
  printf -- '- [ ] Confirm the remote default branch is `main`.\n'
  printf -- '- [ ] Confirm Actions policy is enabled as intended.\n'
  printf -- '- [ ] Confirm Discussions is enabled.\n'
  printf -- '- [ ] Confirm private vulnerability reporting is enabled.\n'
  printf -- '- [ ] Confirm Dependabot alerts and security updates are enabled.\n'
  printf -- '- [ ] Confirm `main` branch protection denies force-push and deletion without requiring unavailable reviewers.\n'
  printf -- '- [ ] Confirm every expected asset name was present exactly once while the release was a draft.\n'
  printf -- '- [ ] Confirm the collision-safe redownload matches every digest in the local publication packet before cleanup.\n'
  printf -- '- [ ] Confirm the final release is published as a prerelease, is not a draft, and is not the latest stable release.\n'
} >"$publication_checklist"
chmod 0644 "$publication_checklist"
payloads+=("$publication_plan" "$publication_checklist")

manifest_inputs=$(mktemp "$artifact_root/.agent-loki-manifest-inputs.XXXXXX")
temporary_manifest=$(mktemp "$artifact_root/.agent-loki-release-manifest.XXXXXX")
for payload in "${payloads[@]}"; do
  upload=false
  for public_upload in "${public_uploads[@]}"; do
    [[ "$payload" != "$public_upload" ]] || upload=true
  done
  printf '%s|%s|%s\n' "$(basename "$payload")" "$(release_mime_type "$payload")" "$upload" >>"$manifest_inputs"
done

MANIFEST_TAG=$release_tag \
MANIFEST_VERSION=$release_version \
MANIFEST_MARKETING=$release_marketing \
MANIFEST_CANONICAL_COMMIT=$canonical_commit \
MANIFEST_CANONICAL_TAG_OBJECT=$canonical_tag_object \
MANIFEST_PUBLICATION_COMMIT=$publication_commit \
MANIFEST_PUBLICATION_MAIN_COMMIT=$publication_main_commit \
MANIFEST_PUBLICATION_TREE=$publication_tree \
MANIFEST_PUBLICATION_TAG_OBJECT=$publication_tag_object \
MANIFEST_REPOSITORY=$github_repository \
MANIFEST_BINARY_STATUS=$binary_status \
MANIFEST_SOURCE_STATUS=$source_status \
MANIFEST_CHECKSUM_FILE=$(basename "$checksums") \
MANIFEST_FILE=$(basename "$manifest") \
MANIFEST_PACKET_FILE=$(basename "$publication_packet") \
MANIFEST_PLAN_FILE=$(basename "$publication_plan") \
MANIFEST_CHECKLIST_FILE=$(basename "$publication_checklist") \
python3 - "$artifact_root" "$manifest_inputs" "$temporary_manifest" <<'PY'
import hashlib
import json
import os
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
assets = []
for line in pathlib.Path(sys.argv[2]).read_text(encoding="utf-8").splitlines():
    name, mime_type, public_upload = line.split("|", 2)
    payload = root / name
    digest = hashlib.sha256(payload.read_bytes()).hexdigest()
    assets.append({
        "mimeType": mime_type,
        "name": name,
        "publicUpload": public_upload == "true",
        "sha256": digest,
        "size": payload.stat().st_size,
    })
assets.sort(key=lambda item: item["name"].encode("utf-8"))
public_asset_names = [item["name"] for item in assets if item["publicUpload"]]
checksum_entries = sorted(
    public_asset_names + [os.environ["MANIFEST_FILE"]],
    key=lambda value: value.encode("utf-8"),
)
final_uploads = sorted(
    checksum_entries + [os.environ["MANIFEST_CHECKSUM_FILE"]],
    key=lambda value: value.encode("utf-8"),
)
manifest = {
    "artifacts": assets,
    "binaryStatus": os.environ["MANIFEST_BINARY_STATUS"],
    "canonicalCommit": os.environ["MANIFEST_CANONICAL_COMMIT"],
    "canonicalTagObject": os.environ["MANIFEST_CANONICAL_TAG_OBJECT"],
    "checksumFile": os.environ["MANIFEST_CHECKSUM_FILE"],
    "checksumEntryFiles": checksum_entries,
    "finalUploadFiles": final_uploads,
    "githubRepository": os.environ["MANIFEST_REPOSITORY"],
    "localPublicationPacket": {
        "generatedAfterChecksums": True,
        "mimeType": "application/json",
        "name": os.environ["MANIFEST_PACKET_FILE"],
        "publicUpload": False,
    },
    "localControlFiles": sorted([
        os.environ["MANIFEST_CHECKLIST_FILE"],
        os.environ["MANIFEST_PACKET_FILE"],
        os.environ["MANIFEST_PLAN_FILE"],
    ], key=lambda value: value.encode("utf-8")),
    "marketingVersion": os.environ["MANIFEST_MARKETING"],
    "publicationActionsExecuted": False,
    "publicationCommit": os.environ["MANIFEST_PUBLICATION_COMMIT"],
    "publicationMainCommit": os.environ["MANIFEST_PUBLICATION_MAIN_COMMIT"],
    "publicationTree": os.environ["MANIFEST_PUBLICATION_TREE"],
    "publicationTagObject": os.environ["MANIFEST_PUBLICATION_TAG_OBJECT"],
    "schemaVersion": 2,
    "sourceStatus": os.environ["MANIFEST_SOURCE_STATUS"],
    "tag": os.environ["MANIFEST_TAG"],
    "version": os.environ["MANIFEST_VERSION"],
}
pathlib.Path(sys.argv[3]).write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
chmod 0644 "$temporary_manifest"
mv "$temporary_manifest" "$manifest"
temporary_manifest=
rm -f "$manifest_inputs"
manifest_inputs=
assert_validated_inputs_unchanged
assert_release_refs_unchanged

checksum_command=("$release_script_dir/generate-checksums.sh" --tag "$release_tag" --artifact-root "$artifact_root")
checksum_payloads=("${public_uploads[@]}" "$manifest")
for payload in "${checksum_payloads[@]}"; do
  checksum_command+=(--artifact "$payload")
done
"${checksum_command[@]}"
assert_validated_inputs_unchanged
assert_release_refs_unchanged

checksum_reproduction=$(mktemp "$artifact_root/.agent-loki-checksum-reproduction.XXXXXX")
: >"$checksum_reproduction"
for payload in "${checksum_payloads[@]}"; do
  printf '%s  %s\n' "$(release_sha256 "$payload")" "$(basename "$payload")" >>"$checksum_reproduction"
done
LC_ALL=C sort -o "$checksum_reproduction" "$checksum_reproduction"
cmp -s "$checksum_reproduction" "$checksums" ||
  release_die "published checksum file does not reproduce from the exact upload payloads"
(
  cd "$artifact_root"
  shasum -a 256 -c "$(basename "$checksums")" >/dev/null
) || release_die "published checksum entries did not verify"
checksum_entry_count=${#checksum_payloads[@]}
checksum_digest=$(release_sha256 "$checksums")

packet_inputs=$(mktemp "$artifact_root/.agent-loki-publication-packet-inputs.XXXXXX")
final_uploads=("${public_uploads[@]}" "$manifest" "$checksums")
for upload in "${final_uploads[@]}"; do
  checksum_entry=true
  [[ "$upload" != "$checksums" ]] || checksum_entry=false
  printf '%s|%s|%s|%s\n' \
    "$(basename "$upload")" \
    "$(release_mime_type "$upload")" \
    "$(release_sha256 "$upload")" \
    "$checksum_entry" >>"$packet_inputs"
done

temporary_packet=$(mktemp "$artifact_root/.agent-loki-publication-packet.XXXXXX")
PACKET_TAG=$release_tag \
PACKET_VERSION=$release_version \
PACKET_CANONICAL_TAG_OBJECT=$canonical_tag_object \
PACKET_COMMIT=$publication_commit \
PACKET_MAIN_COMMIT=$publication_main_commit \
PACKET_TREE=$publication_tree \
PACKET_PUBLICATION_TAG_OBJECT=$publication_tag_object \
PACKET_CHECKSUM_FILE=$(basename "$checksums") \
PACKET_CHECKSUM_SHA256=$checksum_digest \
PACKET_CHECKSUM_ENTRY_COUNT=$checksum_entry_count \
PACKET_FILE=$(basename "$publication_packet") \
PACKET_PLAN_FILE=$(basename "$publication_plan") \
PACKET_PLAN_SHA256=$(release_sha256 "$publication_plan") \
PACKET_CHECKLIST_FILE=$(basename "$publication_checklist") \
PACKET_CHECKLIST_SHA256=$(release_sha256 "$publication_checklist") \
python3 - "$packet_inputs" "$temporary_packet" <<'PY'
import json
import os
import pathlib
import sys

uploads = []
names = set()
for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    name, mime_type, digest, checksum_entry = line.split("|", 3)
    if name in names:
        raise SystemExit(f"duplicate final upload name: {name}")
    names.add(name)
    uploads.append({
        "checksumEntry": checksum_entry == "true",
        "mimeType": mime_type,
        "name": name,
        "sha256": digest,
    })
uploads.sort(key=lambda item: item["name"].encode("utf-8"))
checksum_name = os.environ["PACKET_CHECKSUM_FILE"]
checksum_items = [item for item in uploads if item["name"] == checksum_name]
if len(checksum_items) != 1:
    raise SystemExit("final upload inventory must contain exactly one checksum file")
if checksum_items[0]["checksumEntry"]:
    raise SystemExit("checksum file must not claim a self checksum entry")
if checksum_items[0]["sha256"] != os.environ["PACKET_CHECKSUM_SHA256"]:
    raise SystemExit("checksum file digest does not match the outer packet binding")
covered = [item for item in uploads if item["checksumEntry"]]
if len(covered) != int(os.environ["PACKET_CHECKSUM_ENTRY_COUNT"]):
    raise SystemExit("checksum entry count does not match final covered uploads")

record = {
    "canonicalTagObject": os.environ["PACKET_CANONICAL_TAG_OBJECT"],
    "checksum": {
        "entriesVerified": True,
        "entryCount": len(covered),
        "mimeType": "text/plain",
        "name": checksum_name,
        "reproductionVerified": True,
        "sha256": os.environ["PACKET_CHECKSUM_SHA256"],
    },
    "localControlReceipt": {
        "mimeType": "application/json",
        "name": os.environ["PACKET_FILE"],
        "publicUpload": False,
    },
    "localControls": sorted([
        {
            "mimeType": "text/markdown",
            "name": os.environ["PACKET_CHECKLIST_FILE"],
            "publicUpload": False,
            "sha256": os.environ["PACKET_CHECKLIST_SHA256"],
        },
        {
            "mimeType": "text/plain",
            "name": os.environ["PACKET_PLAN_FILE"],
            "publicUpload": False,
            "sha256": os.environ["PACKET_PLAN_SHA256"],
        },
        {
            "digestOmittedToAvoidSelfReference": True,
            "mimeType": "application/json",
            "name": os.environ["PACKET_FILE"],
            "publicUpload": False,
        },
    ], key=lambda item: item["name"].encode("utf-8")),
    "publicationActionsExecuted": False,
    "publicationCommit": os.environ["PACKET_COMMIT"],
    "publicationMainCommit": os.environ["PACKET_MAIN_COMMIT"],
    "publicationTree": os.environ["PACKET_TREE"],
    "publicationTagObject": os.environ["PACKET_PUBLICATION_TAG_OBJECT"],
    "publicUpload": False,
    "schemaVersion": 1,
    "status": "verified-local-publication-packet",
    "tag": os.environ["PACKET_TAG"],
    "uploads": uploads,
    "version": os.environ["PACKET_VERSION"],
}
pathlib.Path(sys.argv[2]).write_text(
    json.dumps(record, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY
chmod 0644 "$temporary_packet"
mv "$temporary_packet" "$publication_packet"
temporary_packet=

python3 - "$artifact_root" "$manifest" "$checksums" "$publication_packet" <<'PY'
import hashlib
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
manifest_path = pathlib.Path(sys.argv[2])
checksums_path = pathlib.Path(sys.argv[3])
packet_path = pathlib.Path(sys.argv[4])

def load_object(path, label):
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise SystemExit(f"terminal {label} validation failed: {error}")
    if not isinstance(value, dict):
        raise SystemExit(f"terminal {label} validation failed: root must be an object")
    return value

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

manifest = load_object(manifest_path, "manifest")
packet = load_object(packet_path, "publication packet")
checksum_entries = {}
for line in checksums_path.read_text(encoding="utf-8").splitlines():
    match = re.fullmatch(r"([0-9a-f]{64})  ([^/\s]+)", line)
    if match is None or match.group(2) in checksum_entries:
        raise SystemExit("terminal checksum validation failed: malformed or duplicate entry")
    checksum_entries[match.group(2)] = match.group(1)

if set(checksum_entries) != set(manifest.get("checksumEntryFiles", [])):
    raise SystemExit("terminal checksum validation failed: manifest entry inventory differs")
for name, expected_digest in checksum_entries.items():
    if digest(root / name) != expected_digest:
        raise SystemExit(f"terminal checksum validation failed: {name} changed")

artifact_names = set()
for artifact in manifest.get("artifacts", []):
    if not isinstance(artifact, dict) or not isinstance(artifact.get("name"), str):
        raise SystemExit("terminal manifest validation failed: malformed artifact")
    name = artifact["name"]
    if name in artifact_names or pathlib.PurePath(name).name != name:
        raise SystemExit("terminal manifest validation failed: duplicate or unsafe artifact name")
    artifact_names.add(name)
    path = root / name
    artifact_size = artifact.get("size")
    if type(artifact_size) is not int or artifact_size < 0:
        raise SystemExit(f"terminal manifest validation failed: {name} size is malformed")
    if digest(path) != artifact.get("sha256") or path.stat().st_size != artifact_size:
        raise SystemExit(f"terminal manifest validation failed: {name} changed")

uploads = packet.get("uploads")
if not isinstance(uploads, list):
    raise SystemExit("terminal packet validation failed: uploads must be an array")
packet_names = set()
for upload in uploads:
    if not isinstance(upload, dict) or not isinstance(upload.get("name"), str):
        raise SystemExit("terminal packet validation failed: malformed upload")
    name = upload["name"]
    if name in packet_names or pathlib.PurePath(name).name != name:
        raise SystemExit("terminal packet validation failed: duplicate or unsafe upload name")
    packet_names.add(name)
    current_digest = digest(root / name)
    if current_digest != upload.get("sha256"):
        raise SystemExit(f"terminal packet validation failed: {name} changed")
    has_checksum = name in checksum_entries
    if type(upload.get("checksumEntry")) is not bool or upload["checksumEntry"] != has_checksum:
        raise SystemExit(f"terminal packet validation failed: {name} checksum classification differs")
    if has_checksum and checksum_entries[name] != current_digest:
        raise SystemExit(f"terminal packet validation failed: {name} checksum digest differs")

if packet_names != set(manifest.get("finalUploadFiles", [])):
    raise SystemExit("terminal packet validation failed: final upload inventory differs")
local_controls = packet.get("localControls")
if not isinstance(local_controls, list):
    raise SystemExit("terminal packet validation failed: localControls must be an array")
local_control_names = set()
for control in local_controls:
    if not isinstance(control, dict) or not isinstance(control.get("name"), str):
        raise SystemExit("terminal packet validation failed: malformed local control")
    name = control["name"]
    if name in local_control_names or pathlib.PurePath(name).name != name:
        raise SystemExit("terminal packet validation failed: duplicate or unsafe local control name")
    local_control_names.add(name)
    if control.get("publicUpload") is not False:
        raise SystemExit(f"terminal packet validation failed: {name} is not local-only")
    if name == packet_path.name:
        if control.get("digestOmittedToAvoidSelfReference") is not True or "sha256" in control:
            raise SystemExit("terminal packet validation failed: packet self-reference is not explicit")
    elif digest(root / name) != control.get("sha256"):
        raise SystemExit(f"terminal packet validation failed: local control {name} changed")
if local_control_names != set(manifest.get("localControlFiles", [])):
    raise SystemExit("terminal packet validation failed: local control inventory differs")
checksum_digest = digest(checksums_path)
if packet.get("checksum", {}).get("sha256") != checksum_digest:
    raise SystemExit("terminal packet validation failed: checksum file digest differs")
packet_entry_count = packet.get("checksum", {}).get("entryCount")
if type(packet_entry_count) is not int or packet_entry_count != len(checksum_entries):
    raise SystemExit("terminal packet validation failed: checksum entry count differs")
for key in (
    "canonicalTagObject", "publicationCommit", "publicationMainCommit",
    "publicationTagObject", "publicationTree", "tag", "version",
):
    if packet.get(key) != manifest.get(key):
        raise SystemExit(f"terminal packet validation failed: {key} differs from manifest")
PY

assert_validated_inputs_unchanged
assert_release_refs_unchanged
rm -f "$checksum_reproduction" "$packet_inputs"
checksum_reproduction=
packet_inputs=
preparation_complete=true
trap - EXIT HUP INT TERM

printf '%s\n' "$manifest"
printf '%s\n' "$checksums"
printf '%s\n' "$publication_plan"
printf '%s\n' "$publication_checklist"
printf '%s\n' "$publication_packet"
printf 'prepare-github-release: remote-actions=none\n'
