#!/bin/bash
set -euo pipefail

RELEASE_PROGRAM=notarize-dmg
release_script_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P)
# shellcheck source=release-common.sh
source "$release_script_dir/release-common.sh"

usage() {
  cat >&2 <<'USAGE'
usage: scripts/notarize-dmg.sh --tag TAG --artifact-root ABSOLUTE_DIR \
  --dmg ABSOLUTE_DMG --team-id TEAM_ID --certificate-fingerprint SHA1 \
  --keychain-profile PROFILE [--dry-run]

Submits the signed DMG with an explicitly named existing notarytool Keychain
profile, waits for acceptance, privacy-scans and retains the exact log as a
mode-0600 non-upload artifact, staples, and runs the strict public-DMG verifier.
Credential values are never printed or copied into the public summary.
USAGE
}

release_tag=
artifact_root_input=
dmg_input=
expected_team=
expected_fingerprint=
keychain_profile=
dry_run=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      release_require_value "$1" "${2-}"
      release_tag=$2
      shift 2
      ;;
    --artifact-root)
      release_require_value "$1" "${2-}"
      artifact_root_input=$2
      shift 2
      ;;
    --dmg)
      release_require_value "$1" "${2-}"
      dmg_input=$2
      shift 2
      ;;
    --team-id)
      release_require_value "$1" "${2-}"
      expected_team=$2
      shift 2
      ;;
    --certificate-fingerprint)
      release_require_value "$1" "${2-}"
      expected_fingerprint=$2
      shift 2
      ;;
    --keychain-profile)
      release_require_value "$1" "${2-}"
      keychain_profile=$2
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

[[ -n "$release_tag" && -n "$artifact_root_input" && -n "$dmg_input" &&
   -n "$expected_team" && -n "$expected_fingerprint" && -n "$keychain_profile" ]] || {
  usage
  release_usage_error "--tag, --artifact-root, --dmg, --team-id, --certificate-fingerprint, and --keychain-profile are required"
}
[[ "$expected_team" =~ ^[A-Z0-9]{10}$ ]] || release_usage_error "Team ID must be 10 uppercase letters or digits"
release_validate_certificate_fingerprint "$expected_fingerprint"
release_validate_text "Keychain profile" "$keychain_profile"

release_root=$(release_repository_root_from_script "$release_script_dir")
artifact_root=$(release_resolve_existing_directory "$artifact_root_input")
dmg=$(release_assert_direct_child_file "$artifact_root" "$dmg_input")
release_assert_artifact_root "$release_root" "$artifact_root"
release_assert_repo_clean_tag "$release_root" "$release_tag"
release_assert_release_metadata "$release_root" "$release_tag"

asset_prefix=$(release_asset_prefix "$release_tag")
release_assert_expected_basename "$dmg" "${asset_prefix}-macOS-universal.dmg"
notarization_record="$artifact_root/${asset_prefix}-NOTARIZATION.json"
notarization_private_log="$artifact_root/${asset_prefix}-NOTARIZATION-LOG-PRIVATE.json"
dmg_verification_record="$artifact_root/${asset_prefix}-DMG-VERIFICATION.json"
release_assert_output_absent "$notarization_record"
release_assert_output_absent "$notarization_private_log"
release_assert_output_absent "$dmg_verification_record"

if [[ "$dry_run" == true ]]; then
  release_print_command xcrun notarytool submit "$dmg" --keychain-profile '<explicit-profile>' --wait --output-format json
  release_print_command xcrun notarytool log '<submission-id>' --keychain-profile '<explicit-profile>' '<task-owned-log>'
  printf 'private-notary-log=%s mode=0600 public-upload=false\n' "$notarization_private_log"
  release_print_command xcrun stapler staple "$dmg"
  release_print_command "$release_script_dir/verify-dmg.sh" --tag "$release_tag" --artifact-root "$artifact_root" --dmg "$dmg" --team-id "$expected_team" --certificate-fingerprint "$expected_fingerprint"
  printf 'notarize-dmg: execution=not-requested\n'
  exit 0
fi

for required_command in codesign python3 shasum xcrun; do
  release_require_command "$required_command"
done
release_assert_signed_dmg "$dmg" "$expected_team" "$expected_fingerprint"

notary_work_root=$(mktemp -d "$artifact_root/.agent-loki-notary.${release_tag}.XXXXXX")
cleanup_notary_root() {
  case "$notary_work_root/" in
    "$artifact_root"/.agent-loki-notary."$release_tag".*/*) rm -rf "$notary_work_root" ;;
    *) printf 'notarize-dmg: refusing unsafe cleanup target\n' >&2 ;;
  esac
}
trap cleanup_notary_root EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

submission_result="$notary_work_root/submission.json"
notary_log="$notary_work_root/notary-log.json"
xcrun notarytool submit \
  "$dmg" \
  --keychain-profile "$keychain_profile" \
  --wait \
  --output-format json >"$submission_result"

submission_status=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8")).get("status", ""))' "$submission_result")
submission_id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8")).get("id", ""))' "$submission_result")
[[ "$submission_status" == Accepted ]] || release_die "Apple notarization did not return Accepted"
[[ "$submission_id" =~ ^[0-9A-Fa-f-]{36}$ ]] || release_die "notarization submission ID is missing or invalid"

xcrun notarytool log \
  "$submission_id" \
  --keychain-profile "$keychain_profile" \
  "$notary_log" >/dev/null
(umask 077; cp "$notary_log" "$notarization_private_log")
chmod 0600 "$notarization_private_log"
if ! private_log_scan=$(python3 - "$notarization_private_log" <<'PY'
import collections
import json
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
raw = path.read_text(encoding="utf-8")
document = json.loads(raw)
findings = collections.Counter()

patterns = {
    "absolute-macos-user-path": r"/(?:Users)/[^/\s\"<>]+(?:/|$)",
    "absolute-linux-user-path": r"/(?:home)/[^/\s\"<>]+(?:/|$)",
    "absolute-windows-user-path": r"[A-Za-z]:[\\/]Users[\\/][^\\/\s\"<>]+(?:[\\/]|$)",
    "email-address": r"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b",
    "private-key-material": r"-----BEGIN(?: [A-Z0-9]+)? PRIVATE KEY-----",
}
for classification, pattern in patterns.items():
    findings[classification] += len(re.findall(pattern, raw, flags=re.IGNORECASE))

sensitive_keys = {
    "apikey",
    "app-specific-password",
    "appspecificpassword",
    "credential",
    "credentials",
    "password",
    "privatekey",
    "secret",
    "token",
}

def walk(value):
    if isinstance(value, dict):
        for key, item in value.items():
            normalized = re.sub(r"[^a-z-]", "", str(key).lower())
            if normalized in sensitive_keys and item not in (None, "", [], {}):
                findings["credential-like-field"] += 1
            walk(item)
    elif isinstance(value, list):
        for item in value:
            walk(item)

walk(document)
findings = collections.Counter({key: count for key, count in findings.items() if count})
print(",".join(f"{key}={findings[key]}" for key in sorted(findings)) or "none")
if findings["private-key-material"] or findings["credential-like-field"]:
    raise SystemExit(3)
PY
); then
  release_die "private notarization log contains credential-like material; exact mode-0600 log retained outside the public upload set"
fi
printf 'notarize-dmg: private-log-scan=%s public-upload=false\n' "$private_log_scan"
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg" >/dev/null

"$release_script_dir/verify-dmg.sh" \
  --tag "$release_tag" \
  --artifact-root "$artifact_root" \
  --dmg "$dmg" \
  --team-id "$expected_team" \
  --certificate-fingerprint "$expected_fingerprint" \
  --output-record "$dmg_verification_record"

final_dmg_digest=$(release_sha256 "$dmg")
NOTARY_TAG=$release_tag \
NOTARY_VERSION=$(release_version_from_tag "$release_tag") \
NOTARY_DMG=$(basename "$dmg") \
NOTARY_SHA256=$final_dmg_digest \
NOTARY_FINGERPRINT=$expected_fingerprint \
NOTARY_PRIVATE_LOG_SCAN=$private_log_scan \
python3 - "$submission_result" "$notary_log" "$notarization_record" <<'PY'
import json
import os
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    submission = json.load(handle)
with open(sys.argv[2], encoding="utf-8") as handle:
    log = json.load(handle)
issues = log.get("issues") or []
record = {
    "certificateFingerprintSha1": os.environ["NOTARY_FINGERPRINT"],
    "dmg": os.environ["NOTARY_DMG"],
    "dmgSha256AfterStapling": os.environ["NOTARY_SHA256"],
    "issueCount": len(issues),
    "logStatusCode": log.get("statusCode"),
    "logStatusSummary": log.get("statusSummary"),
    "privateLogPublicUpload": False,
    "privateLogScan": os.environ["NOTARY_PRIVATE_LOG_SCAN"],
    "schemaVersion": 1,
    "staplerValidated": True,
    "status": submission.get("status"),
    "submissionId": submission.get("id"),
    "tag": os.environ["NOTARY_TAG"],
    "version": os.environ["NOTARY_VERSION"],
}
with open(sys.argv[3], "x", encoding="utf-8", newline="\n") as handle:
    json.dump(record, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
chmod 0644 "$notarization_record"

trap - EXIT HUP INT TERM
rm -rf "$notary_work_root"
printf '%s\n' "$notarization_record"
