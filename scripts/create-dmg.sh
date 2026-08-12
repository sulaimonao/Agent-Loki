#!/bin/bash
set -euo pipefail

RELEASE_PROGRAM=create-dmg
release_script_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P)
# shellcheck source=release-common.sh
source "$release_script_dir/release-common.sh"

usage() {
  cat >&2 <<'USAGE'
usage: scripts/create-dmg.sh --tag TAG --artifact-root ABSOLUTE_DIR \
  --app ABSOLUTE_APP --identity DEVELOPER_ID_IDENTITY --team-id TEAM_ID \
  --certificate-fingerprint SHA1 \
  [--dry-run]
       scripts/create-dmg.sh --unsigned-inspection --tag TAG \
  --artifact-root ABSOLUTE_DIR --app ABSOLUTE_UNSIGNED_APP [--dry-run]

Creates and Developer-ID-signs the deterministic public DMG. The input app must
already have a valid Developer ID signature, Hardened Runtime, and no debug
entitlement. This script never creates an unsigned public-named DMG.

--unsigned-inspection is a separate nonpublic path. It refuses identity and
Team ID inputs, requires an unsigned universal app, verifies the mounted image,
and emits only the exact UNSIGNED-NOT-FOR-PUBLIC-DISTRIBUTION artifact name.
USAGE
}

release_tag=
artifact_root_input=
app_input=
signing_identity=
expected_team=
expected_fingerprint=
unsigned_inspection=false
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
    --app)
      release_require_value "$1" "${2-}"
      app_input=$2
      shift 2
      ;;
    --identity)
      release_require_value "$1" "${2-}"
      signing_identity=$2
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
    --unsigned-inspection)
      unsigned_inspection=true
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

[[ -n "$release_tag" && -n "$artifact_root_input" && -n "$app_input" ]] || {
  usage
  release_usage_error "--tag, --artifact-root, and --app are required"
}
if [[ "$unsigned_inspection" == true ]]; then
  [[ -z "$signing_identity" && -z "$expected_team" && -z "$expected_fingerprint" ]] ||
    release_usage_error "--unsigned-inspection refuses --identity, --team-id, and --certificate-fingerprint"
else
  [[ -n "$signing_identity" && -n "$expected_team" && -n "$expected_fingerprint" ]] || {
    usage
    release_usage_error "signed public mode requires --identity, --team-id, and --certificate-fingerprint"
  }
  release_validate_text "signing identity" "$signing_identity"
  [[ "$expected_team" =~ ^[A-Z0-9]{10}$ ]] ||
    release_usage_error "Team ID must be 10 uppercase letters or digits"
  release_validate_certificate_fingerprint "$expected_fingerprint"
fi

release_root=$(release_repository_root_from_script "$release_script_dir")
artifact_root=$(release_resolve_existing_directory "$artifact_root_input")
app=$(release_resolve_existing_app "$app_input")
release_assert_artifact_root "$release_root" "$artifact_root"
release_assert_within_root "$artifact_root" "$app"
release_assert_repo_clean_tag "$release_root" "$release_tag"
release_assert_release_metadata "$release_root" "$release_tag"

asset_prefix=$(release_asset_prefix "$release_tag")
if [[ "$unsigned_inspection" == true ]]; then
  dmg_basename=$(release_unsigned_inspection_dmg_basename "$release_tag")
else
  dmg_basename="${asset_prefix}-macOS-universal.dmg"
fi
dmg_path="$artifact_root/$dmg_basename"
release_assert_output_absent "$dmg_path"
expected_marketing=$(release_marketing_version_from_tag "$release_tag")
expected_build=$(release_project_build_number "$release_root")

if [[ "$dry_run" == true ]]; then
  if [[ "$unsigned_inspection" == true ]]; then
    printf 'DRY-RUN: verify unsigned app metadata, universal architectures, and quarantine absence\n'
    release_print_command hdiutil create -volname "Agent Loki $release_tag" -srcfolder '<task-owned-staging>' -format UDZO "$dmg_path"
    printf 'DRY-RUN: verify unsigned DMG, mount read-only, and check exact app metadata, universal architectures, Applications link, and top-level content\n'
    printf 'create-dmg: classification=UNSIGNED_NOT_FOR_PUBLIC_DISTRIBUTION\n'
    printf 'create-dmg: output=%s\n' "$dmg_basename"
    printf 'create-dmg: execution=not-requested\n'
    exit 0
  fi
  printf 'DRY-RUN: verify Developer ID signature, Team ID, Hardened Runtime, entitlements, and universal architectures\n'
  release_print_command hdiutil create -volname "Agent Loki $release_tag" -srcfolder '<task-owned-staging>' -format UDZO "$dmg_path"
  release_print_command codesign --force --timestamp --sign "$expected_fingerprint" "$dmg_path"
  printf 'create-dmg: output=%s\n' "$(basename "$dmg_path")"
  printf 'create-dmg: execution=not-requested\n'
  exit 0
fi

for required_command in codesign ditto file find hdiutil lipo ln openssl python3 readlink; do
  release_require_command "$required_command"
done
if [[ "$unsigned_inspection" == true ]]; then
  release_assert_unsigned_app "$app" "$expected_marketing" "$expected_build"
else
  release_require_command security
  release_assert_signing_identity_available "$signing_identity" "$expected_fingerprint"
  release_assert_signed_app \
    "$app" "$expected_team" "$expected_fingerprint" \
    "$expected_marketing" "$expected_build" "$release_root" "$artifact_root"
  release_assert_no_quarantine "$app"
fi

dmg_work_root=$(mktemp -d "$artifact_root/.agent-loki-dmg.${release_tag}.XXXXXX")
dmg_mount_root=
dmg_is_mounted=false
cleanup_dmg_root() {
  if [[ "$dmg_is_mounted" == true && -n "$dmg_mount_root" ]]; then
    hdiutil detach "$dmg_mount_root" >/dev/null 2>&1 ||
      hdiutil detach -force "$dmg_mount_root" >/dev/null 2>&1 || true
  fi
  case "$dmg_work_root/" in
    "$artifact_root"/.agent-loki-dmg."$release_tag".*/*) rm -rf "$dmg_work_root" ;;
    *) printf 'create-dmg: refusing unsafe cleanup target\n' >&2 ;;
  esac
}
trap cleanup_dmg_root EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

staging_root="$dmg_work_root/staging"
mkdir "$staging_root"
ditto "$app" "$staging_root/LokiBrief.app"
ln -s /Applications "$staging_root/Applications"

temporary_dmg="$dmg_work_root/$dmg_basename"
hdiutil create \
  -quiet \
  -volname "Agent Loki $release_tag" \
  -srcfolder "$staging_root" \
  -format UDZO \
  "$temporary_dmg"
if [[ "$unsigned_inspection" == true ]]; then
  release_assert_unsigned_code_object "$temporary_dmg" "inspection DMG"
  hdiutil verify "$temporary_dmg" >/dev/null
  dmg_mount_root="$dmg_work_root/mount"
  mkdir "$dmg_mount_root"
  hdiutil attach -quiet -readonly -nobrowse -mountpoint "$dmg_mount_root" "$temporary_dmg"
  dmg_is_mounted=true
  mounted_app=$(release_mounted_dmg_app "$dmg_mount_root")
  release_assert_unsigned_app "$mounted_app" "$expected_marketing" "$expected_build"
  hdiutil detach "$dmg_mount_root" >/dev/null
  dmg_is_mounted=false
else
  codesign --force --timestamp --sign "$expected_fingerprint" "$temporary_dmg"
  release_assert_signed_dmg "$temporary_dmg" "$expected_team" "$expected_fingerprint"
fi
chmod 0644 "$temporary_dmg"
mv "$temporary_dmg" "$dmg_path"

trap - EXIT HUP INT TERM
rm -rf "$dmg_work_root"
if [[ "$unsigned_inspection" == true ]]; then
  printf 'create-dmg: classification=UNSIGNED_NOT_FOR_PUBLIC_DISTRIBUTION\n' >&2
fi
printf '%s\n' "$dmg_path"
