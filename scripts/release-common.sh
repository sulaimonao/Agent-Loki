#!/bin/bash
# Shared fail-closed helpers for the local release scripts. This file is meant
# to be sourced; it performs no release action by itself.

if [[ -n "${AGENT_LOKI_RELEASE_COMMON_LOADED:-}" ]]; then
  return 0
fi
AGENT_LOKI_RELEASE_COMMON_LOADED=1

release_program=${RELEASE_PROGRAM:-agent-loki-release}

release_die() {
  printf '%s: %s\n' "$release_program" "$*" >&2
  exit 1
}

release_usage_error() {
  printf '%s: %s\n' "$release_program" "$*" >&2
  exit 2
}

release_require_value() {
  local option=$1
  local value=${2-}
  [[ -n "$value" ]] || release_usage_error "$option requires a value"
}

release_require_command() {
  command -v "$1" >/dev/null 2>&1 || release_die "required command is unavailable: $1"
}

release_validate_text() {
  local label=$1
  local value=$2
  [[ -n "$value" ]] || release_usage_error "$label must not be empty"
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] ||
    release_usage_error "$label must be one line"
}

release_validate_slack_client_id() {
  local value=$1
  local byte_count
  byte_count=$(LC_ALL=C printf '%s' "$value" | wc -c | tr -d ' ')
  [[ "$byte_count" -ge 1 && "$byte_count" -le 256 ]] ||
    release_usage_error "Slack Client ID must be between 1 and 256 ASCII bytes"
  [[ "$value" != --* ]] ||
    release_usage_error "Slack Client ID is missing or option-like"
  [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]] ||
    release_usage_error "Slack Client ID contains unsupported characters"
  [[ "$value" =~ [A-Za-z0-9] ]] ||
    release_usage_error "Slack Client ID must contain an ASCII letter or digit"
}

release_validate_tag() {
  local tag=$1
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-rc\.[0-9]+$ ]] ||
    release_usage_error "tag must match vMAJOR.MINOR.PATCH-rc.NUMBER"
}

release_validate_certificate_fingerprint() {
  local fingerprint=$1
  [[ "$fingerprint" =~ ^[0-9A-F]{40}$ ]] ||
    release_usage_error "certificate fingerprint must be exactly 40 uppercase hexadecimal characters"
}

release_assert_signing_identity_available() {
  local identity=$1
  local fingerprint=$2
  local identities
  local match_count
  release_validate_text "signing identity" "$identity"
  release_validate_certificate_fingerprint "$fingerprint"
  identities=$(security find-identity -v -p codesigning 2>/dev/null) ||
    release_die "unable to enumerate code-signing identities"
  match_count=$(
    printf '%s\n' "$identities" |
      awk -v fingerprint="$fingerprint" -v identity="\"$identity\"" '
        index($0, fingerprint) && index($0, identity) { count += 1 }
        END { print count + 0 }
      '
  )
  [[ "$match_count" == 1 ]] ||
    release_die "the requested identity and certificate fingerprint do not identify exactly one available code-signing identity"
}

release_version_from_tag() {
  local tag=$1
  release_validate_tag "$tag"
  printf '%s\n' "${tag#v}"
}

release_marketing_version_from_tag() {
  local version
  version=$(release_version_from_tag "$1")
  printf '%s\n' "${version%%-rc.*}"
}

release_asset_prefix() {
  release_validate_tag "$1"
  printf 'Agent-Loki-%s\n' "$1"
}

release_unsigned_inspection_dmg_basename() {
  printf '%s-macOS-universal-UNSIGNED-NOT-FOR-PUBLIC-DISTRIBUTION.dmg\n' \
    "$(release_asset_prefix "$1")"
}

release_resolve_existing_directory() {
  local input=$1
  [[ "$input" = /* ]] || release_usage_error "directory must be absolute: $input"
  [[ -d "$input" ]] || release_usage_error "directory does not exist: $input"
  [[ ! -L "$input" ]] || release_usage_error "directory must not be a symbolic link: $input"
  (CDPATH= cd -P "$input" && pwd -P)
}

release_resolve_existing_file() {
  local input=$1
  local parent
  local base
  [[ "$input" = /* ]] || release_usage_error "file must be absolute: $input"
  [[ -f "$input" ]] || release_usage_error "regular file does not exist: $input"
  [[ ! -L "$input" ]] || release_usage_error "file must not be a symbolic link: $input"
  parent=$(release_resolve_existing_directory "$(dirname "$input")")
  base=$(basename "$input")
  printf '%s/%s\n' "$parent" "$base"
}

release_resolve_existing_app() {
  local input=$1
  local parent
  local base
  [[ "$input" = /* ]] || release_usage_error "application path must be absolute: $input"
  [[ -d "$input" && "$input" == *.app ]] ||
    release_usage_error "application bundle does not exist: $input"
  [[ ! -L "$input" ]] || release_usage_error "application must not be a symbolic link: $input"
  parent=$(release_resolve_existing_directory "$(dirname "$input")")
  base=$(basename "$input")
  printf '%s/%s\n' "$parent" "$base"
}

release_resolve_new_file() {
  local input=$1
  local parent
  local base
  [[ "$input" = /* ]] || release_usage_error "output path must be absolute: $input"
  parent=$(release_resolve_existing_directory "$(dirname "$input")")
  base=$(basename "$input")
  [[ "$base" != "." && "$base" != ".." && "$base" != */* ]] ||
    release_usage_error "invalid output filename: $base"
  printf '%s/%s\n' "$parent" "$base"
}

release_assert_output_absent() {
  local output=$1
  [[ ! -e "$output" && ! -L "$output" ]] ||
    release_die "refusing to overwrite existing output: $output"
}

release_assert_within_root() {
  local root=$1
  local path=$2
  case "$path/" in
    "$root"/*) ;;
    *) release_usage_error "path must remain inside the artifact root: $path" ;;
  esac
  [[ "$path" != "$root" ]] || release_usage_error "artifact path must not be the artifact root itself"
}

release_assert_direct_child_file() {
  local root=$1
  local input=$2
  local resolved
  resolved=$(release_resolve_existing_file "$input")
  release_assert_within_root "$root" "$resolved"
  [[ "$(dirname "$resolved")" == "$root" ]] ||
    release_usage_error "release payload must be a direct child of the artifact root: $resolved"
  printf '%s\n' "$resolved"
}

release_assert_expected_basename() {
  local path=$1
  local expected=$2
  [[ "$(basename "$path")" == "$expected" ]] ||
    release_usage_error "expected artifact name $expected, got $(basename "$path")"
}

release_assert_artifact_root() {
  local repository_root=$1
  local artifact_root=$2
  case "$artifact_root/" in
    "$repository_root"/*) release_usage_error "artifact root must be outside the source repository" ;;
  esac
}

release_repository_root_from_script() {
  local script_dir=$1
  local root
  root=$(git -C "$script_dir/.." rev-parse --show-toplevel 2>/dev/null) ||
    release_die "scripts must run from a Git repository"
  release_resolve_existing_directory "$root"
}

release_assert_repo_clean_tag() {
  local repository=$1
  local tag=$2
  local tag_type
  local tag_commit
  local head_commit
  release_validate_tag "$tag"
  repository=$(release_resolve_existing_directory "$repository")
  git -C "$repository" rev-parse --git-dir >/dev/null 2>&1 ||
    release_die "not a Git repository: $repository"
  tag_type=$(git -C "$repository" cat-file -t "refs/tags/$tag" 2>/dev/null || true)
  [[ "$tag_type" == tag ]] || release_die "release tag must exist and be annotated: $tag"
  tag_commit=$(git -C "$repository" rev-parse "refs/tags/$tag^{commit}")
  head_commit=$(git -C "$repository" rev-parse HEAD)
  [[ "$head_commit" == "$tag_commit" ]] ||
    release_die "wrong tag: HEAD $head_commit does not match $tag at $tag_commit"
  [[ -z "$(git -C "$repository" status --porcelain --untracked-files=all)" ]] ||
    release_die "source repository is dirty: $repository"
}

release_project_file() {
  printf '%s\n' "$1/macos/LokiBrief/LokiBrief.xcodeproj/project.pbxproj"
}

release_project_build_number() {
  local repository=$1
  local project
  local values
  project=$(release_project_file "$repository")
  [[ -f "$project" ]] || release_die "Xcode project file is missing: $project"
  values=$(sed -nE 's/.*CURRENT_PROJECT_VERSION = ([^;]+);.*/\1/p' "$project" | LC_ALL=C sort -u)
  [[ -n "$values" && "$(printf '%s\n' "$values" | wc -l | tr -d ' ')" == 1 ]] ||
    release_die "Xcode build number is missing or inconsistent"
  printf '%s\n' "$values"
}

release_assert_release_metadata() {
  local repository=$1
  local tag=$2
  local project
  local expected_marketing
  local marketing_values
  local expected_source_version
  local package_version
  project=$(release_project_file "$repository")
  expected_marketing=$(release_marketing_version_from_tag "$tag")
  expected_source_version=$(release_version_from_tag "$tag")
  [[ -f "$project" ]] || release_die "Xcode project file is missing: $project"
  marketing_values=$(sed -nE 's/.*MARKETING_VERSION = ([^;]+);.*/\1/p' "$project" | LC_ALL=C sort -u)
  [[ "$marketing_values" == "$expected_marketing" ]] ||
    release_die "Xcode marketing version does not match $tag (expected $expected_marketing)"
  [[ -f "$repository/package.json" ]] || release_die "package.json is missing"
  package_version=$(sed -nE 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$repository/package.json" | sed -n '1p')
  [[ "$package_version" == "$expected_source_version" ]] ||
    release_die "package.json version $package_version does not match $tag"
  release_project_build_number "$repository" >/dev/null
}

release_plist_value() {
  local plist=$1
  local key=$2
  /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null
}

release_assert_app_metadata() {
  local app=$1
  local expected_version=$2
  local expected_build=$3
  local plist=$app/Contents/Info.plist
  local actual_version
  local actual_build
  local bundle_id
  [[ -f "$plist" ]] || release_die "application Info.plist is missing: $plist"
  actual_version=$(release_plist_value "$plist" CFBundleShortVersionString) ||
    release_die "application marketing version is missing"
  actual_build=$(release_plist_value "$plist" CFBundleVersion) ||
    release_die "application build number is missing"
  bundle_id=$(release_plist_value "$plist" CFBundleIdentifier) ||
    release_die "application bundle identifier is missing"
  [[ "$actual_version" == "$expected_version" ]] ||
    release_die "application marketing version $actual_version does not match $expected_version"
  [[ "$actual_build" == "$expected_build" ]] ||
    release_die "application build number $actual_build does not match $expected_build"
  [[ "$bundle_id" == com.agentloki.LokiBrief ]] ||
    release_die "unexpected application bundle identifier: $bundle_id"
}

release_assert_app_slack_client_id() {
  local app=$1
  local expected_client_id=$2
  local plist=$app/Contents/Info.plist
  local actual_client_id
  [[ -f "$plist" ]] || release_die "application Info.plist is missing: $plist"
  actual_client_id=$(release_plist_value "$plist" LOKI_SLACK_CLIENT_ID) ||
    release_die "application Slack Client ID is missing"
  [[ "$actual_client_id" == "$expected_client_id" ]] ||
    release_die "application Slack Client ID does not match the explicit release input"
}

release_app_executable() {
  local app=$1
  local executable
  executable=$(release_plist_value "$app/Contents/Info.plist" CFBundleExecutable) ||
    release_die "application executable name is missing"
  printf '%s/Contents/MacOS/%s\n' "$app" "$executable"
}

release_assert_universal_app() {
  local app=$1
  local executable
  executable=$(release_app_executable "$app")
  [[ -f "$executable" ]] || release_die "application executable is missing: $executable"
  release_assert_universal_macho "$executable" "application executable"
}

release_assert_universal_macho() {
  local executable=$1
  local label=$2
  local architectures
  local architecture
  [[ -f "$executable" && ! -L "$executable" ]] ||
    release_die "$label is missing or is not a regular file: $executable"
  file -b "$executable" 2>/dev/null | grep -q '^Mach-O' ||
    release_die "$label is not Mach-O code: $executable"
  architectures=$(lipo -archs "$executable" 2>/dev/null) ||
    release_die "unable to inspect architectures for $label"
  [[ " $architectures " == *" arm64 "* && " $architectures " == *" x86_64 "* ]] ||
    release_die "$label is not universal arm64+x86_64: $architectures"
  for architecture in $architectures; do
    [[ "$architecture" == arm64 || "$architecture" == x86_64 ]] ||
      release_die "$label contains an unexpected architecture: $architecture"
  done
}

release_assert_no_quarantine() {
  local path=$1
  if command -v xattr >/dev/null 2>&1 &&
     xattr -lr "$path" 2>/dev/null | grep -F 'com.apple.quarantine' >/dev/null; then
    release_die "quarantine metadata is present in the release input: $path"
  fi
}

release_assert_unsigned_code_object() {
  local target=$1
  local label=$2
  if codesign -d --verbose=4 "$target" >/dev/null 2>&1; then
    release_die "$label must be unsigned"
  fi
}

release_assert_unsigned_app() {
  local app=$1
  local expected_version=$2
  local expected_build=$3
  release_assert_app_metadata "$app" "$expected_version" "$expected_build"
  release_assert_universal_app "$app"
  release_assert_unsigned_code_object "$app" "inspection application"
  release_assert_no_quarantine "$app"
}

release_mounted_dmg_app() {
  local mount_root=$1
  local actual_entries
  local expected_entries
  local applications_link=$mount_root/Applications
  local mounted_app=$mount_root/LokiBrief.app
  actual_entries=$(
    find "$mount_root" -mindepth 1 -maxdepth 1 -print |
      while IFS= read -r entry; do basename "$entry"; done |
      LC_ALL=C sort
  )
  expected_entries=$(printf '%s\n' Applications LokiBrief.app | LC_ALL=C sort)
  [[ "$actual_entries" == "$expected_entries" ]] ||
    release_die "DMG top-level content must contain only LokiBrief.app and the Applications link"
  [[ -L "$applications_link" ]] ||
    release_die "DMG Applications entry must be a symbolic link"
  [[ "$(readlink "$applications_link")" == /Applications ]] ||
    release_die "DMG Applications link must target /Applications"
  [[ -d "$mounted_app" && ! -L "$mounted_app" ]] ||
    release_die "DMG must contain a regular LokiBrief.app bundle"
  printf '%s\n' "$mounted_app"
}

release_codesign_details() {
  codesign -dv --verbose=4 "$1" 2>&1
}

release_code_identifier() {
  local path=$1
  local details
  details=$(release_codesign_details "$path") ||
    release_die "unable to inspect the code-signing identifier: $path"
  printf '%s\n' "$details" | sed -n 's/^Identifier=//p' | sed -n '1p'
}

release_assert_code_identifier() {
  local path=$1
  local expected_identifier=$2
  local actual_identifier
  actual_identifier=$(release_code_identifier "$path")
  [[ "$actual_identifier" == "$expected_identifier" ]] ||
    release_die "unexpected code-signing identifier for $path: $actual_identifier"
}

release_assert_bundle_metadata() {
  local plist=$1
  local expected_identifier=$2
  local expected_executable=$3
  local expected_version=$4
  local expected_build=$5
  local expected_type=$6
  local label=$7
  local actual
  [[ -f "$plist" ]] || release_die "$label Info.plist is missing: $plist"
  actual=$(release_plist_value "$plist" CFBundleIdentifier) ||
    release_die "$label bundle identifier is missing"
  [[ "$actual" == "$expected_identifier" ]] ||
    release_die "$label bundle identifier does not match $expected_identifier"
  actual=$(release_plist_value "$plist" CFBundleExecutable) ||
    release_die "$label executable name is missing"
  [[ "$actual" == "$expected_executable" ]] ||
    release_die "$label executable name does not match $expected_executable"
  actual=$(release_plist_value "$plist" CFBundleShortVersionString) ||
    release_die "$label marketing version is missing"
  [[ "$actual" == "$expected_version" ]] ||
    release_die "$label marketing version does not match $expected_version"
  actual=$(release_plist_value "$plist" CFBundleVersion) ||
    release_die "$label build number is missing"
  [[ "$actual" == "$expected_build" ]] ||
    release_die "$label build number does not match $expected_build"
  actual=$(release_plist_value "$plist" CFBundlePackageType) ||
    release_die "$label package type is missing"
  [[ "$actual" == "$expected_type" ]] ||
    release_die "$label package type does not match $expected_type"
}

release_assert_expected_code_inventory() {
  local app=$1
  local actual_machos
  local expected_machos
  local actual_bundles
  local expected_bundles
  local actual_executables
  local actual_symlinks
  local expected_symlinks
  local candidate
  local relative
  actual_machos=$(
    find "$app/Contents" -type f -print0 |
      while IFS= read -r -d '' candidate; do
        if file -b "$candidate" 2>/dev/null | grep -q '^Mach-O'; then
          relative=${candidate#"$app"/}
          printf '%s\n' "$relative"
        fi
      done |
      LC_ALL=C sort
  )
  expected_machos=$(
    printf '%s\n' \
      'Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate' \
      'Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle' \
      'Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater' \
      'Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader' \
      'Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer' \
      'Contents/MacOS/LokiBrief' |
      LC_ALL=C sort
  )
  [[ "$actual_machos" == "$expected_machos" ]] ||
    release_die "application Mach-O inventory differs from the exact release allowlist"
  actual_executables=$(
    find "$app/Contents" -type f -perm -111 -print |
      while IFS= read -r candidate; do
        relative=${candidate#"$app"/}
        printf '%s\n' "$relative"
      done |
      LC_ALL=C sort
  )
  [[ "$actual_executables" == "$expected_machos" ]] ||
    release_die "application executable-file inventory differs from the exact release allowlist"

  actual_bundles=$(
    find "$app/Contents" -type d \
      \( -name '*.framework' -o -name '*.xpc' -o -name '*.appex' -o -name '*.app' -o -name '*.bundle' \) \
      -print |
      while IFS= read -r candidate; do
        relative=${candidate#"$app"/}
        printf '%s\n' "$relative"
      done |
      LC_ALL=C sort
  )
  expected_bundles=$(
    printf '%s\n' \
      'Contents/Frameworks/Sparkle.framework' \
      'Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app' \
      'Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc' \
      'Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc' |
      LC_ALL=C sort
  )
  [[ "$actual_bundles" == "$expected_bundles" ]] ||
    release_die "application nested code-bundle inventory differs from the exact release allowlist"

  actual_symlinks=$(
    find "$app/Contents" -type l -print |
      while IFS= read -r candidate; do
        relative=${candidate#"$app"/}
        printf '%s -> %s\n' "$relative" "$(readlink "$candidate")"
      done |
      LC_ALL=C sort
  )
  expected_symlinks=$(
    printf '%s\n' \
      'Contents/Frameworks/Sparkle.framework/Autoupdate -> Versions/Current/Autoupdate' \
      'Contents/Frameworks/Sparkle.framework/Resources -> Versions/Current/Resources' \
      'Contents/Frameworks/Sparkle.framework/Sparkle -> Versions/Current/Sparkle' \
      'Contents/Frameworks/Sparkle.framework/Updater.app -> Versions/Current/Updater.app' \
      'Contents/Frameworks/Sparkle.framework/Versions/Current -> B' \
      'Contents/Frameworks/Sparkle.framework/XPCServices -> Versions/Current/XPCServices' |
      LC_ALL=C sort
  )
  [[ "$actual_symlinks" == "$expected_symlinks" ]] ||
    release_die "application symbolic-link inventory differs from the exact release allowlist"

  release_assert_bundle_metadata \
    "$app/Contents/Frameworks/Sparkle.framework/Versions/B/Resources/Info.plist" \
    org.sparkle-project.Sparkle Sparkle 2.9.4 2059 FMWK "Sparkle framework"
  release_assert_bundle_metadata \
    "$app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/Info.plist" \
    org.sparkle-project.Sparkle.Updater Updater 2.9.4 2059 APPL "Sparkle Updater"
  release_assert_bundle_metadata \
    "$app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/Info.plist" \
    org.sparkle-project.DownloaderService Downloader 2.9.4 2059 'XPC!' "Sparkle Downloader"
  release_assert_bundle_metadata \
    "$app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/Info.plist" \
    org.sparkle-project.InstallerLauncher Installer 2.9.4 2059 'XPC!' "Sparkle Installer"
}

release_assert_expected_code_architectures() {
  local app=$1
  release_assert_universal_macho \
    "$app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader" \
    "Sparkle Downloader executable"
  release_assert_universal_macho \
    "$app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer" \
    "Sparkle Installer executable"
  release_assert_universal_macho \
    "$app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater" \
    "Sparkle Updater executable"
  release_assert_universal_macho \
    "$app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" \
    "Sparkle Autoupdate executable"
  release_assert_universal_macho \
    "$app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" \
    "Sparkle framework executable"
  release_assert_universal_macho \
    "$app/Contents/MacOS/LokiBrief" \
    "LokiBrief executable"
}

release_assert_code_entitlements() {
  local path=$1
  local expectation=$2
  local artifact_root=$3
  local source_entitlements=${4-}
  local expected_team=${5-}
  local bundle_id=${6-}
  local actual_entitlements
  actual_entitlements=$(mktemp "$artifact_root/.agent-loki-entitlements.XXXXXX")
  if ! codesign -d --entitlements :- "$path" >"$actual_entitlements" 2>/dev/null; then
    rm -f "$actual_entitlements"
    release_die "unable to inspect code entitlements: $path"
  fi
  if ! python3 - "$actual_entitlements" "$expectation" "$source_entitlements" "$expected_team" "$bundle_id" <<'PY'
import pathlib
import plistlib
import sys

actual_path, expectation, source_path, team, bundle_id = sys.argv[1:]
raw = pathlib.Path(actual_path).read_bytes()
actual = {} if not raw else plistlib.loads(raw)
if not isinstance(actual, dict):
    raise SystemExit("signed entitlements must be a dictionary")
if "com.apple.security.get-task-allow" in actual:
    raise SystemExit("get-task-allow entitlement is forbidden")

if expectation == "empty":
    expected = {}
elif expectation == "autoupdate":
    expected = {
        "com.apple.application-identifier":
            "org.sparkle-project.Sparkle.Autoupdate",
    }
elif expectation == "application":
    if not source_path or not team or not bundle_id:
        raise SystemExit("application entitlement comparison is missing inputs")
    with open(source_path, "rb") as handle:
        expected = plistlib.load(handle)

    def expand(value):
        if isinstance(value, str):
            return value.replace("$(AppIdentifierPrefix)", f"{team}.").replace(
                "$(DevelopmentTeam)", team
            ).replace(
                "$(PRODUCT_BUNDLE_IDENTIFIER)", bundle_id
            )
        if isinstance(value, list):
            return [expand(item) for item in value]
        if isinstance(value, dict):
            return {key: expand(item) for key, item in value.items()}
        return value

    expected = expand(expected)
else:
    raise SystemExit(f"unknown entitlement expectation: {expectation}")

if actual != expected:
    raise SystemExit("signed entitlements differ from the exact expected entitlement dictionary")
PY
  then
    rm -f "$actual_entitlements"
    release_die "exact entitlement verification failed: $path"
  fi
  rm -f "$actual_entitlements"
}

release_assert_pre_sign_code_object() {
  local path=$1
  local expected_identifier=$2
  local allow_stripped_framework_seal=$3
  local details
  local verification_output
  if ! verification_output=$(codesign --verify --strict --verbose=2 "$path" 2>&1); then
    if [[ "$allow_stripped_framework_seal" != true ]] ||
       ! printf '%s\n' "$verification_output" | grep -F 'a sealed resource is missing or invalid' >/dev/null; then
      release_die "pre-sign nested code has an unexpected signature-integrity failure: $path"
    fi
  elif [[ "$allow_stripped_framework_seal" != false && "$allow_stripped_framework_seal" != true ]]; then
    release_die "invalid internal pre-sign framework-seal expectation"
  fi
  details=$(release_codesign_details "$path") ||
    release_die "unable to inspect pre-sign nested code: $path"
  printf '%s\n' "$details" | grep -Fx 'Signature=adhoc' >/dev/null ||
    release_die "pre-sign nested code has an unexpected non-ad-hoc signature: $path"
  printf '%s\n' "$details" | grep -Fx 'TeamIdentifier=not set' >/dev/null ||
    release_die "pre-sign nested code unexpectedly carries a Team identifier: $path"
  release_assert_code_identifier "$path" "$expected_identifier"
}

release_assert_pre_sign_outer_app() {
  local app=$1
  local artifact_root=$2
  local details
  local unexpected_profile
  unexpected_profile=$(
    find "$app" \( -name embedded.provisionprofile -o -name embedded.mobileprovision \) \
      -print -quit
  )
  [[ -z "$unexpected_profile" ]] ||
    release_die "pre-sign application contains an unexpected provisioning profile"
  if ! details=$(release_codesign_details "$app" 2>/dev/null); then
    return 0
  fi
  printf '%s\n' "$details" | grep -Fx 'Signature=adhoc' >/dev/null ||
    release_die "pre-sign application has an unexpected non-ad-hoc signature"
  printf '%s\n' "$details" | grep -Fx 'TeamIdentifier=not set' >/dev/null ||
    release_die "pre-sign application unexpectedly carries a Team identifier"
  printf '%s\n' "$details" | grep -E '^CodeDirectory .* flags=0x[0-9a-f]+\(adhoc,linker-signed\) ' >/dev/null ||
    release_die "pre-sign application signature is not the bounded linker ad-hoc form"
  printf '%s\n' "$details" | grep -Fx 'Sealed Resources=none' >/dev/null ||
    release_die "pre-sign application unexpectedly seals bundle resources"
  printf '%s\n' "$details" | grep -Fx 'Internal requirements=none' >/dev/null ||
    release_die "pre-sign application unexpectedly carries internal requirements"
  ! printf '%s\n' "$details" | grep -q '^Authority=' ||
    release_die "pre-sign application unexpectedly carries a signing authority"
  release_assert_code_entitlements "$app" empty "$artifact_root"
}

release_assert_pre_sign_app() {
  local app=$1
  local artifact_root=$2
  local framework=$app/Contents/Frameworks/Sparkle.framework
  release_assert_expected_code_inventory "$app"
  release_assert_expected_code_architectures "$app"
  release_assert_pre_sign_outer_app "$app" "$artifact_root"
  release_assert_pre_sign_code_object \
    "$framework/Versions/B/XPCServices/Downloader.xpc" \
    org.sparkle-project.DownloaderService false
  release_assert_pre_sign_code_object \
    "$framework/Versions/B/XPCServices/Installer.xpc" \
    org.sparkle-project.InstallerLauncher false
  release_assert_pre_sign_code_object \
    "$framework/Versions/B/Updater.app" \
    org.sparkle-project.Sparkle.Updater false
  release_assert_pre_sign_code_object \
    "$framework/Versions/B/Autoupdate" \
    Autoupdate-555549442401fd215d503466a26c3d081e5a8443 false
  release_assert_pre_sign_code_object \
    "$framework" \
    org.sparkle-project.Sparkle true
  release_assert_code_entitlements \
    "$framework/Versions/B/XPCServices/Downloader.xpc" empty "$artifact_root"
  release_assert_code_entitlements \
    "$framework/Versions/B/XPCServices/Installer.xpc" empty "$artifact_root"
  release_assert_code_entitlements \
    "$framework/Versions/B/Updater.app" empty "$artifact_root"
  release_assert_code_entitlements \
    "$framework/Versions/B/Autoupdate" autoupdate "$artifact_root"
  release_assert_code_entitlements \
    "$framework" empty "$artifact_root"
}

release_assert_developer_id_signature() {
  local path=$1
  local expected_team=$2
  local expected_fingerprint=${3-}
  local runtime_required=${4-}
  local details
  local designated_requirement
  local developer_id_requirement
  release_validate_certificate_fingerprint "$expected_fingerprint"
  codesign --verify --strict --verbose=2 "$path" >/dev/null 2>&1 ||
    release_die "code signature verification failed: $path"
  developer_id_requirement="anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = \"$expected_team\" and certificate leaf = H\"$expected_fingerprint\""
  codesign --verify --strict --verbose=2 "-R=$developer_id_requirement" "$path" >/dev/null 2>&1 ||
    release_die "code signature does not match the exact Developer ID certificate requirement: $path"
  details=$(release_codesign_details "$path") || release_die "unable to inspect code signature: $path"
  printf '%s\n' "$details" | grep -F 'Authority=Developer ID Application:' >/dev/null ||
    release_die "artifact is not signed with Developer ID Application: $path"
  ! printf '%s\n' "$details" | grep -F 'Signature=adhoc' >/dev/null ||
    release_die "ad-hoc signature is forbidden: $path"
  printf '%s\n' "$details" | grep -Fx "TeamIdentifier=$expected_team" >/dev/null ||
    release_die "code-signing Team ID does not match $expected_team: $path"
  printf '%s\n' "$details" | grep -q '^Timestamp=' ||
    release_die "secure code-signing timestamp is missing: $path"
  designated_requirement=$(codesign -d -r- "$path" 2>&1) ||
    release_die "unable to inspect the designated requirement: $path"
  printf '%s\n' "$designated_requirement" | grep -F 'designated =>' >/dev/null ||
    release_die "valid designated requirement is missing: $path"
  if [[ "$runtime_required" == true ]]; then
    printf '%s\n' "$details" | grep -E '^CodeDirectory .* flags=.*\(.*runtime.*\) ' >/dev/null ||
      release_die "Hardened Runtime flag is missing: $path"
  elif [[ "$runtime_required" != false ]]; then
    release_die "invalid internal Hardened Runtime expectation"
  fi
}

release_assert_developer_id_provisioning_profile() {
  local profile=$1
  local expected_team=$2
  local expected_fingerprint=$3
  local expected_bundle_id=$4
  local artifact_root=$5
  local decoded_profile
  local profile_signer
  local signer_certificate_count
  local signer_subject
  local signer_provisioning_oid_count
  local system_root_keychain=/System/Library/Keychains/SystemRootCertificates.keychain
  [[ -f "$profile" && ! -L "$profile" ]] ||
    release_die "Developer ID provisioning profile must be a regular non-symbolic-link file: $profile"
  [[ -f "$system_root_keychain" && ! -L "$system_root_keychain" ]] ||
    release_die "macOS system root certificate keychain is unavailable"
  release_validate_certificate_fingerprint "$expected_fingerprint"
  decoded_profile=$(mktemp "$artifact_root/.agent-loki-provisioning-profile.XXXXXX")
  profile_signer=$(mktemp "$artifact_root/.agent-loki-provisioning-signer.XXXXXX")
  chmod 0600 "$decoded_profile"
  chmod 0600 "$profile_signer"
  if ! openssl cms -verify -inform DER -in "$profile" -noverify \
    -out "$decoded_profile" -signer "$profile_signer" >/dev/null 2>&1; then
    rm -f "$decoded_profile" "$profile_signer"
    release_die "Developer ID provisioning-profile CMS signature verification failed"
  fi
  signer_certificate_count=$(grep -c '^-----BEGIN CERTIFICATE-----$' "$profile_signer" || true)
  if [[ "$signer_certificate_count" != 1 ]]; then
    rm -f "$decoded_profile" "$profile_signer"
    release_die "Developer ID provisioning profile must have exactly one CMS signer"
  fi
  if ! security verify-cert -L -R offline -p basic -N \
    -k "$system_root_keychain" -c "$profile_signer" -q; then
    rm -f "$decoded_profile" "$profile_signer"
    release_die "Developer ID provisioning-profile signer is not trusted by macOS system roots"
  fi
  signer_subject=$(
    openssl x509 -in "$profile_signer" -noout -subject -nameopt RFC2253 2>/dev/null |
      sed 's/^subject= *//'
  )
  if [[ "$signer_subject" != 'C=US,O=Apple Inc.,CN=Mac OS X Provisioning Profile Signing' ]]; then
    rm -f "$decoded_profile" "$profile_signer"
    release_die "Developer ID provisioning profile has an unexpected CMS signer identity"
  fi
  signer_provisioning_oid_count=$(
    openssl x509 -in "$profile_signer" -noout -text 2>/dev/null |
      grep -F -c '1.2.840.113635.100.4.11:' || true
  )
  if [[ "$signer_provisioning_oid_count" != 1 ]]; then
    rm -f "$decoded_profile" "$profile_signer"
    release_die "Developer ID provisioning-profile signer lacks the exact Apple provisioning OID"
  fi
  if ! python3 - \
    "$decoded_profile" "$expected_team" "$expected_fingerprint" "$expected_bundle_id" <<'PY'
import datetime
import hashlib
import pathlib
import plistlib
import sys
import uuid

profile_path, team, fingerprint, bundle_id = sys.argv[1:]
with open(profile_path, "rb") as handle:
    profile = plistlib.load(handle)

if profile.get("Version") != 1:
    raise SystemExit("unexpected provisioning-profile version")
if profile.get("Platform") != ["OSX"]:
    raise SystemExit("provisioning profile is not an exact macOS profile")
if profile.get("TeamIdentifier") != [team]:
    raise SystemExit("provisioning-profile TeamIdentifier differs from the expected Team ID")
if profile.get("ApplicationIdentifierPrefix") != [team]:
    raise SystemExit("provisioning-profile application prefix differs from the expected Team ID")
if profile.get("ProvisionsAllDevices") is not True:
    raise SystemExit("provisioning profile is not a Developer ID all-devices profile")
if "ProvisionedDevices" in profile:
    raise SystemExit("device-scoped provisioning profile is forbidden for Developer ID distribution")

creation = profile.get("CreationDate")
expiration = profile.get("ExpirationDate")
now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
if not isinstance(creation, datetime.datetime) or creation > now:
    raise SystemExit("provisioning profile has an invalid creation date")
if not isinstance(expiration, datetime.datetime) or expiration <= now:
    raise SystemExit("provisioning profile is expired or lacks an expiration date")
try:
    uuid.UUID(str(profile.get("UUID")))
except (TypeError, ValueError, AttributeError):
    raise SystemExit("provisioning profile UUID is invalid")

expected_entitlements = {
    "com.apple.application-identifier": f"{team}.{bundle_id}",
    "com.apple.developer.team-identifier": team,
    "keychain-access-groups": [f"{team}.*"],
}
if profile.get("Entitlements") != expected_entitlements:
    raise SystemExit("provisioning-profile entitlements differ from the exact release authorization")

certificate_fingerprints = {
    hashlib.sha1(certificate).hexdigest().upper()
    for certificate in profile.get("DeveloperCertificates", [])
}
if fingerprint not in certificate_fingerprints:
    raise SystemExit("expected Developer ID certificate is absent from the provisioning profile")
PY
  then
    rm -f "$decoded_profile" "$profile_signer"
    release_die "Developer ID provisioning-profile validation failed"
  fi
  rm -f "$decoded_profile" "$profile_signer"
}

release_assert_nested_code_signatures() {
  local app=$1
  local expected_team=$2
  local expected_fingerprint=$3
  local artifact_root=$4
  local framework=$app/Contents/Frameworks/Sparkle.framework
  release_assert_expected_code_inventory "$app"
  release_assert_expected_code_architectures "$app"
  release_assert_developer_id_signature \
    "$framework/Versions/B/XPCServices/Downloader.xpc" \
    "$expected_team" "$expected_fingerprint" true
  release_assert_code_identifier \
    "$framework/Versions/B/XPCServices/Downloader.xpc" \
    org.sparkle-project.DownloaderService
  release_assert_code_entitlements \
    "$framework/Versions/B/XPCServices/Downloader.xpc" empty "$artifact_root"
  release_assert_developer_id_signature \
    "$framework/Versions/B/XPCServices/Installer.xpc" \
    "$expected_team" "$expected_fingerprint" true
  release_assert_code_identifier \
    "$framework/Versions/B/XPCServices/Installer.xpc" \
    org.sparkle-project.InstallerLauncher
  release_assert_code_entitlements \
    "$framework/Versions/B/XPCServices/Installer.xpc" empty "$artifact_root"
  release_assert_developer_id_signature \
    "$framework/Versions/B/Updater.app" \
    "$expected_team" "$expected_fingerprint" true
  release_assert_code_identifier \
    "$framework/Versions/B/Updater.app" \
    org.sparkle-project.Sparkle.Updater
  release_assert_code_entitlements \
    "$framework/Versions/B/Updater.app" empty "$artifact_root"
  release_assert_developer_id_signature \
    "$framework/Versions/B/Autoupdate" \
    "$expected_team" "$expected_fingerprint" true
  release_assert_code_identifier \
    "$framework/Versions/B/Autoupdate" \
    Autoupdate-555549442401fd215d503466a26c3d081e5a8443
  release_assert_code_entitlements \
    "$framework/Versions/B/Autoupdate" autoupdate "$artifact_root"
  release_assert_developer_id_signature \
    "$framework" \
    "$expected_team" "$expected_fingerprint" true
  release_assert_code_identifier \
    "$framework" \
    org.sparkle-project.Sparkle
  release_assert_code_entitlements "$framework" empty "$artifact_root"
}

release_assert_signed_app() {
  local app=$1
  local expected_team=$2
  local expected_fingerprint=${3-}
  local expected_version=${4-}
  local expected_build=${5-}
  local repository_root=${6-}
  local artifact_root=${7-}
  local source_entitlements=$repository_root/macos/LokiBrief/LokiBrief/LokiBrief.entitlements
  local bundle_id
  local embedded_profile
  local profile_inventory
  release_assert_app_metadata "$app" "$expected_version" "$expected_build"
  release_assert_universal_app "$app"
  release_assert_expected_code_inventory "$app"
  release_assert_developer_id_signature \
    "$app" "$expected_team" "$expected_fingerprint" true
  release_assert_code_identifier "$app" com.agentloki.LokiBrief
  [[ -f "$source_entitlements" ]] || release_die "release entitlements are missing"
  bundle_id=$(release_plist_value "$app/Contents/Info.plist" CFBundleIdentifier)
  release_assert_code_entitlements \
    "$app" application "$artifact_root" "$source_entitlements" "$expected_team" "$bundle_id"
  release_assert_nested_code_signatures \
    "$app" "$expected_team" "$expected_fingerprint" "$artifact_root"
  embedded_profile="$app/Contents/embedded.provisionprofile"
  profile_inventory=$(
    find "$app" \( -name embedded.provisionprofile -o -name embedded.mobileprovision \) \
      -print | LC_ALL=C sort
  )
  [[ "$profile_inventory" == "$embedded_profile" ]] ||
    release_die "signed application must contain exactly one app-root embedded.provisionprofile"
  release_assert_developer_id_provisioning_profile \
    "$embedded_profile" "$expected_team" "$expected_fingerprint" "$bundle_id" "$artifact_root"
  codesign --verify --deep --strict --verbose=2 "$app" >/dev/null 2>&1 ||
    release_die "final deep strict application verification failed"
}

release_assert_signed_dmg() {
  local dmg=$1
  local expected_team=$2
  local expected_fingerprint=${3-}
  release_assert_developer_id_signature \
    "$dmg" "$expected_team" "$expected_fingerprint" false
}

release_sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

release_print_command() {
  local argument
  printf 'DRY-RUN:'
  for argument in "$@"; do
    printf ' %q' "$argument"
  done
  printf '\n'
}

release_mime_type() {
  case "$1" in
    *.dmg) printf 'application/x-apple-diskimage\n' ;;
    *.tar.gz) printf 'application/gzip\n' ;;
    *.spdx.json|*SBOM*.json) printf 'application/spdx+json\n' ;;
    *.json) printf 'application/json\n' ;;
    *.md) printf 'text/markdown\n' ;;
    *.txt) printf 'text/plain\n' ;;
    *) printf 'application/octet-stream\n' ;;
  esac
}
