#!/bin/bash
set -euo pipefail

RELEASE_PROGRAM=verify-dmg
release_script_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P)
# shellcheck source=release-common.sh
source "$release_script_dir/release-common.sh"

usage() {
  cat >&2 <<'USAGE'
usage: scripts/verify-dmg.sh --tag TAG --artifact-root ABSOLUTE_DIR \
  --dmg ABSOLUTE_DMG --team-id TEAM_ID --certificate-fingerprint SHA1 \
  [--output-record ABSOLUTE_JSON | --no-record] \
  [--dry-run]

Fails unless the public DMG is Developer-ID-signed, notarization-stapled and
valid, Gatekeeper-accepted, mountable, minimal, and contains the exact signed
universal application plus the Applications link.
USAGE
}

release_tag=
artifact_root_input=
dmg_input=
expected_team=
expected_fingerprint=
output_record_input=
no_record=false
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
    --output-record)
      release_require_value "$1" "${2-}"
      output_record_input=$2
      shift 2
      ;;
    --no-record)
      no_record=true
      shift
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
   -n "$expected_team" && -n "$expected_fingerprint" ]] || {
  usage
  release_usage_error "--tag, --artifact-root, --dmg, --team-id, and --certificate-fingerprint are required"
}
[[ "$expected_team" =~ ^[A-Z0-9]{10}$ ]] || release_usage_error "Team ID must be 10 uppercase letters or digits"
release_validate_certificate_fingerprint "$expected_fingerprint"
[[ "$no_record" == false || -z "$output_record_input" ]] ||
  release_usage_error "--no-record and --output-record are mutually exclusive"

release_root=$(release_repository_root_from_script "$release_script_dir")
artifact_root=$(release_resolve_existing_directory "$artifact_root_input")
dmg=$(release_assert_direct_child_file "$artifact_root" "$dmg_input")
release_assert_artifact_root "$release_root" "$artifact_root"
release_assert_repo_clean_tag "$release_root" "$release_tag"
release_assert_release_metadata "$release_root" "$release_tag"

asset_prefix=$(release_asset_prefix "$release_tag")
release_assert_expected_basename "$dmg" "${asset_prefix}-macOS-universal.dmg"
if [[ "$no_record" == false ]]; then
  if [[ -n "$output_record_input" ]]; then
    output_record=$(release_resolve_new_file "$output_record_input")
    release_assert_within_root "$artifact_root" "$output_record"
    [[ "$(dirname "$output_record")" == "$artifact_root" ]] ||
      release_usage_error "verification record must be a direct child of the artifact root"
  else
    output_record="$artifact_root/${asset_prefix}-DMG-VERIFICATION.json"
  fi
  release_assert_expected_basename "$output_record" "${asset_prefix}-DMG-VERIFICATION.json"
  release_assert_output_absent "$output_record"
fi

if [[ "$dry_run" == true ]]; then
  release_print_command codesign --verify --strict --verbose=2 "$dmg"
  release_print_command hdiutil verify "$dmg"
  release_print_command xcrun stapler validate "$dmg"
  release_print_command spctl -a -t open --context context:primary-signature -v "$dmg"
  release_print_command hdiutil attach -readonly -nobrowse -mountpoint '<task-owned-mount>' "$dmg"
  printf 'DRY-RUN: verify exact DMG contents, mounted app signatures, entitlements, version, and architectures\n'
  printf 'verify-dmg: execution=not-requested\n'
  exit 0
fi

for required_command in codesign file find hdiutil lipo openssl python3 readlink security shasum spctl xcrun; do
  release_require_command "$required_command"
done

release_assert_signed_dmg "$dmg" "$expected_team" "$expected_fingerprint"
hdiutil verify "$dmg" >/dev/null
xcrun stapler validate "$dmg" >/dev/null
spctl -a -t open --context context:primary-signature -v "$dmg" >/dev/null

mount_root=$(mktemp -d "$artifact_root/.agent-loki-dmg-mount.${release_tag}.XXXXXX")
mounted=false
cleanup_mount() {
  if [[ "$mounted" == true ]]; then
    hdiutil detach -quiet "$mount_root" >/dev/null 2>&1 ||
      hdiutil detach -quiet -force "$mount_root" >/dev/null 2>&1 || true
  fi
  case "$mount_root/" in
    "$artifact_root"/.agent-loki-dmg-mount."$release_tag".*/*) rm -rf "$mount_root" ;;
    *) printf 'verify-dmg: refusing unsafe cleanup target\n' >&2 ;;
  esac
}
trap cleanup_mount EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

hdiutil attach -quiet -readonly -nobrowse -mountpoint "$mount_root" "$dmg"
mounted=true

top_level_entries=$(find "$mount_root" -mindepth 1 -maxdepth 1 -exec basename {} \; |
  LC_ALL=C sort)
expected_entries=$(printf '%s\n' Applications LokiBrief.app | LC_ALL=C sort)
[[ "$top_level_entries" == "$expected_entries" ]] ||
  release_die "DMG contains unexpected or missing top-level entries"
[[ -L "$mount_root/Applications" ]] || release_die "DMG Applications entry is not a symbolic link"
[[ "$(readlink "$mount_root/Applications")" == /Applications ]] ||
  release_die "DMG Applications link does not resolve to /Applications"

mounted_app="$mount_root/LokiBrief.app"
[[ -d "$mounted_app" ]] || release_die "DMG does not contain LokiBrief.app"
expected_marketing=$(release_marketing_version_from_tag "$release_tag")
expected_build=$(release_project_build_number "$release_root")
release_assert_signed_app \
  "$mounted_app" "$expected_team" "$expected_fingerprint" \
  "$expected_marketing" "$expected_build" "$release_root" "$artifact_root"
release_assert_no_quarantine "$mounted_app"
spctl -a -t exec -v "$mounted_app" >/dev/null

hdiutil detach -quiet "$mount_root"
mounted=false
rm -rf "$mount_root"
trap - EXIT HUP INT TERM

dmg_digest=$(release_sha256 "$dmg")
if [[ "$no_record" == false ]]; then
  VERIFY_TAG=$release_tag \
  VERIFY_VERSION=$(release_version_from_tag "$release_tag") \
  VERIFY_TEAM=$expected_team \
  VERIFY_FINGERPRINT=$expected_fingerprint \
  VERIFY_DMG=$(basename "$dmg") \
  VERIFY_SHA256=$dmg_digest \
  python3 - "$output_record" <<'PY'
import json
import os
import sys

record = {
    "app": "LokiBrief.app",
    "applicationsLink": "/Applications",
    "architectures": ["arm64", "x86_64"],
    "certificateFingerprintSha1": os.environ["VERIFY_FINGERPRINT"],
    "developerIdTeam": os.environ["VERIFY_TEAM"],
    "designatedRequirementsValid": True,
    "dmg": os.environ["VERIFY_DMG"],
    "exactCodeInventory": True,
    "exactEntitlements": True,
    "gatekeeperAccepted": True,
    "hardenedRuntime": True,
    "notarizationTicketStapled": True,
    "nestedCodeVerified": True,
    "schemaVersion": 1,
    "sha256": os.environ["VERIFY_SHA256"],
    "secureTimestamp": True,
    "status": "verified-for-public-distribution",
    "tag": os.environ["VERIFY_TAG"],
    "version": os.environ["VERIFY_VERSION"],
}
with open(sys.argv[1], "x", encoding="utf-8", newline="\n") as handle:
    json.dump(record, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
  chmod 0644 "$output_record"
  printf '%s\n' "$output_record"
fi
printf 'verify-dmg: passed sha256=%s\n' "$dmg_digest"
