#!/bin/bash
set -euo pipefail

RELEASE_PROGRAM=build-release-app
release_script_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P)
# shellcheck source=release-common.sh
source "$release_script_dir/release-common.sh"

usage() {
  cat >&2 <<'USAGE'
usage: scripts/build-release-app.sh --tag TAG --artifact-root ABSOLUTE_DIR \
  (--slack-client-id CLIENT_ID | --without-slack) [--dry-run]

Builds an unsigned universal Release archive from the clean checkout whose HEAD
is the annotated release tag. A source builder may inject their own nonsecret
Slack desktop-app Client ID through a task-owned temporary xcconfig. Public
portable binaries use --without-slack so no maintainer-specific application
configuration or update authority is embedded. The resulting archive is
checked for empty Slack and update metadata. Signing is handled separately.
USAGE
}

release_tag=
artifact_root_input=
slack_client_id=
slack_configuration=
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
    --slack-client-id)
      release_require_value "$1" "${2-}"
      [[ -z "$slack_configuration" ]] || release_usage_error "choose exactly one Slack configuration mode"
      slack_client_id=$2
      slack_configuration=configured
      shift 2
      ;;
    --without-slack)
      [[ -z "$slack_configuration" ]] || release_usage_error "choose exactly one Slack configuration mode"
      slack_configuration=disabled
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

[[ -n "$release_tag" && -n "$artifact_root_input" && -n "$slack_configuration" ]] || {
  usage
  release_usage_error "--tag, --artifact-root, and exactly one Slack configuration mode are required"
}
if [[ "$slack_configuration" == configured ]]; then
  release_validate_slack_client_id "$slack_client_id"
fi

release_root=$(release_repository_root_from_script "$release_script_dir")
artifact_root=$(release_resolve_existing_directory "$artifact_root_input")
release_assert_artifact_root "$release_root" "$artifact_root"
release_assert_repo_clean_tag "$release_root" "$release_tag"
release_assert_release_metadata "$release_root" "$release_tag"

asset_prefix=$(release_asset_prefix "$release_tag")
archive_path="$artifact_root/${asset_prefix}-macOS-universal.xcarchive"
release_assert_output_absent "$archive_path"
project_path="$release_root/macos/LokiBrief/LokiBrief.xcodeproj"
expected_marketing=$(release_marketing_version_from_tag "$release_tag")
expected_build=$(release_project_build_number "$release_root")

configure_build_command() {
  local xcconfig=$1
  build_command=(
    xcodebuild
    -project "$project_path"
    -scheme LokiBrief
    -configuration Release
    -destination 'generic/platform=macOS'
    -archivePath "$archive_path"
    -xcconfig "$xcconfig"
    -disableAutomaticPackageResolution
    -onlyUsePackageVersionsFromResolvedFile
    -skipPackageUpdates
    "ARCHS=arm64 x86_64"
    ONLY_ACTIVE_ARCH=NO
    CODE_SIGNING_ALLOWED=NO
    CODE_SIGNING_REQUIRED=NO
    DEVELOPMENT_TEAM=
    CODE_SIGN_IDENTITY=
    "MARKETING_VERSION=$expected_marketing"
    "CURRENT_PROJECT_VERSION=$expected_build"
    archive
  )
}

if [[ "$dry_run" == true ]]; then
  if [[ "$slack_configuration" == configured ]]; then
    printf 'DRY-RUN: inject validated Slack Client ID through a task-owned temporary xcconfig (value redacted)\n'
  else
    printf 'DRY-RUN: build with explicitly empty Slack and update metadata for portable public distribution\n'
  fi
  configure_build_command '<task-owned-release-xcconfig>'
  release_print_command "${build_command[@]}"
  printf 'build-release-app: output=%s\n' "$(basename "$archive_path")"
  printf 'build-release-app: execution=not-requested\n'
  exit 0
fi

release_require_command xcodebuild
release_require_command lipo
release_require_command perl

build_work_root=$(mktemp -d "$artifact_root/.agent-loki-build.${release_tag}.XXXXXX")
cleanup_build_work_root() {
  case "$build_work_root/" in
    "$artifact_root"/.agent-loki-build."$release_tag".*/*) rm -rf "$build_work_root" ;;
    *) printf 'build-release-app: refusing unsafe cleanup target\n' >&2 ;;
  esac
}
trap cleanup_build_work_root EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

temporary_xcconfig="$build_work_root/Release.xcconfig"
if [[ "$slack_configuration" == disabled ]]; then
  (
    umask 077
    {
      printf 'LOKI_SLACK_CLIENT_ID =\n'
      printf 'LOKI_UPDATE_STABLE_FEED_URL =\n'
      printf 'LOKI_UPDATE_BETA_FEED_URL =\n'
      printf 'LOKI_UPDATE_INTERNAL_FEED_URL =\n'
      printf 'LOKI_UPDATE_PUBLIC_ED_KEY =\n'
    } >"$temporary_xcconfig"
  )
else
  (umask 077; printf 'LOKI_SLACK_CLIENT_ID = %s\n' "$slack_client_id" >"$temporary_xcconfig")
fi
configure_build_command "$temporary_xcconfig"
"${build_command[@]}" 2>&1 |
  LOKI_RELEASE_REDACTION_VALUE="$slack_client_id" perl -pe '
    BEGIN {
      $redaction_value = delete $ENV{"LOKI_RELEASE_REDACTION_VALUE"};
    }
    s/\Q$redaction_value\E/[REDACTED]/g
      if defined($redaction_value) && $redaction_value ne "";
  '

app_path="$archive_path/Products/Applications/LokiBrief.app"
[[ -d "$app_path" ]] || release_die "archive does not contain LokiBrief.app"
release_assert_app_metadata "$app_path" "$expected_marketing" "$expected_build"
release_assert_app_slack_client_id "$app_path" "$slack_client_id"
if [[ "$slack_configuration" == disabled ]]; then
  for public_metadata_key in \
    LOKI_SLACK_CLIENT_ID \
    LOKI_UPDATE_STABLE_FEED_URL \
    LOKI_UPDATE_BETA_FEED_URL \
    LOKI_UPDATE_INTERNAL_FEED_URL \
    SUPublicEDKey; do
    public_metadata_value=$(release_plist_value "$app_path/Contents/Info.plist" "$public_metadata_key") ||
      release_die "public application metadata is missing: $public_metadata_key"
    [[ -z "$public_metadata_value" ]] ||
      release_die "public application metadata must be empty: $public_metadata_key"
  done
fi
release_assert_universal_app "$app_path"
release_assert_no_quarantine "$app_path"

trap - EXIT HUP INT TERM
rm -rf "$build_work_root"
slack_client_id=

printf '%s\n' "$archive_path"
