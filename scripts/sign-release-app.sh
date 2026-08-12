#!/bin/bash
set -euo pipefail

RELEASE_PROGRAM=sign-release-app
release_script_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P)
# shellcheck source=release-common.sh
source "$release_script_dir/release-common.sh"

usage() {
  cat >&2 <<'USAGE'
usage: scripts/sign-release-app.sh --tag TAG --artifact-root ABSOLUTE_DIR \
  --input-app ABSOLUTE_APP --identity DEVELOPER_ID_IDENTITY --team-id TEAM_ID \
  --certificate-fingerprint SHA1 --provisioning-profile ABSOLUTE_PROFILE \
  [--dry-run]

Copies the unsigned app into a deterministic task-owned directory, expands the
repository entitlements, validates and embeds the app-specific Developer ID
provisioning profile, signs nested code inside-out, signs the app with the
Hardened Runtime, and emits a local privacy-bounded signing record.
USAGE
}

release_tag=
artifact_root_input=
input_app_input=
signing_identity=
expected_team=
expected_fingerprint=
provisioning_profile_input=
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
    --input-app)
      release_require_value "$1" "${2-}"
      input_app_input=$2
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
    --provisioning-profile)
      release_require_value "$1" "${2-}"
      provisioning_profile_input=$2
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

[[ -n "$release_tag" && -n "$artifact_root_input" && -n "$input_app_input" &&
   -n "$signing_identity" && -n "$expected_team" && -n "$expected_fingerprint" &&
   -n "$provisioning_profile_input" ]] || {
  usage
  release_usage_error "--tag, --artifact-root, --input-app, --identity, --team-id, --certificate-fingerprint, and --provisioning-profile are required"
}
release_validate_text "signing identity" "$signing_identity"
[[ "$expected_team" =~ ^[A-Z0-9]{10}$ ]] || release_usage_error "Team ID must be 10 uppercase letters or digits"
release_validate_certificate_fingerprint "$expected_fingerprint"

release_root=$(release_repository_root_from_script "$release_script_dir")
artifact_root=$(release_resolve_existing_directory "$artifact_root_input")
input_app=$(release_resolve_existing_app "$input_app_input")
provisioning_profile=$(release_resolve_existing_file "$provisioning_profile_input")
release_assert_artifact_root "$release_root" "$artifact_root"
release_assert_within_root "$artifact_root" "$input_app"
case "$provisioning_profile/" in
  "$release_root"/*|"$artifact_root"/*)
    release_usage_error "provisioning profile must remain outside the source repository and artifact root"
    ;;
esac
release_assert_repo_clean_tag "$release_root" "$release_tag"
release_assert_release_metadata "$release_root" "$release_tag"

asset_prefix=$(release_asset_prefix "$release_tag")
signed_directory="$artifact_root/${asset_prefix}-signed"
signed_app="$signed_directory/LokiBrief.app"
signing_record="$artifact_root/${asset_prefix}-CODE_SIGNING.json"
release_assert_output_absent "$signed_directory"
release_assert_output_absent "$signing_record"

expected_marketing=$(release_marketing_version_from_tag "$release_tag")
expected_build=$(release_project_build_number "$release_root")
release_assert_app_metadata "$input_app" "$expected_marketing" "$expected_build"
release_assert_universal_app "$input_app"
release_assert_no_quarantine "$input_app"

for required_command in chmod codesign cp ditto file find readlink security lipo openssl plutil python3 shasum; do
  release_require_command "$required_command"
done
release_assert_pre_sign_app "$input_app" "$artifact_root"
bundle_id=$(release_plist_value "$input_app/Contents/Info.plist" CFBundleIdentifier)
release_assert_developer_id_provisioning_profile \
  "$provisioning_profile" "$expected_team" "$expected_fingerprint" "$bundle_id" "$artifact_root"

if [[ "$dry_run" == true ]]; then
  release_print_command ditto "$input_app" "$signed_app"
  release_print_command cp '<validated-local-provisioning-profile>' "$signed_app/Contents/embedded.provisionprofile"
  printf 'DRY-RUN: sign the five exact allowlisted Sparkle code roots inside-out while preserving their validated identifiers and entitlements\n'
  release_print_command codesign --force --timestamp --options runtime --preserve-metadata=identifier,entitlements --sign "$expected_fingerprint" '<allowlisted-nested-code-root>'
  release_print_command codesign --force --timestamp --options runtime --sign "$expected_fingerprint" --entitlements '<expanded-task-owned-entitlements>' "$signed_app"
  printf 'sign-release-app: output=%s/%s\n' "$(basename "$signed_directory")" "$(basename "$signed_app")"
  printf 'sign-release-app: execution=not-requested\n'
  exit 0
fi

release_assert_signing_identity_available "$signing_identity" "$expected_fingerprint"

signing_root=$(mktemp -d "$artifact_root/.agent-loki-sign.${release_tag}.XXXXXX")
cleanup_signing_root() {
  case "$signing_root/" in
    "$artifact_root"/.agent-loki-sign."$release_tag".*/*) rm -rf "$signing_root" ;;
    *) printf 'sign-release-app: refusing unsafe cleanup target\n' >&2 ;;
  esac
}
trap cleanup_signing_root EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

working_app="$signing_root/LokiBrief.app"
expanded_entitlements="$signing_root/release.entitlements"
ditto "$input_app" "$working_app"
release_assert_pre_sign_app "$working_app" "$artifact_root"

source_entitlements="$release_root/macos/LokiBrief/LokiBrief/LokiBrief.entitlements"
[[ -f "$source_entitlements" ]] || release_die "release entitlements are missing"
cp "$provisioning_profile" "$working_app/Contents/embedded.provisionprofile"
chmod 0644 "$working_app/Contents/embedded.provisionprofile"
sed \
  -e "s/\$(AppIdentifierPrefix)/${expected_team}./g" \
  -e "s/\$(DevelopmentTeam)/${expected_team}/g" \
  -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/${bundle_id}/g" \
  "$source_entitlements" >"$expanded_entitlements"
plutil -lint "$expanded_entitlements" >/dev/null

framework="$working_app/Contents/Frameworks/Sparkle.framework"
nested_signing_roots=(
  "$framework/Versions/B/XPCServices/Downloader.xpc"
  "$framework/Versions/B/XPCServices/Installer.xpc"
  "$framework/Versions/B/Updater.app"
  "$framework/Versions/B/Autoupdate"
  "$framework"
)
for nested_code in "${nested_signing_roots[@]}"; do
  codesign \
    --force \
    --timestamp \
    --options runtime \
    --preserve-metadata=identifier,entitlements \
    --sign "$expected_fingerprint" \
    "$nested_code"
done

codesign \
  --force \
  --timestamp \
  --options runtime \
  --sign "$expected_fingerprint" \
  --entitlements "$expanded_entitlements" \
  "$working_app"

release_assert_signed_app \
  "$working_app" "$expected_team" "$expected_fingerprint" \
  "$expected_marketing" "$expected_build" "$release_root" "$artifact_root"
rm -f "$expanded_entitlements"
mv "$signing_root" "$signed_directory"
signing_root=
trap - EXIT HUP INT TERM

python3 - \
  "$signing_record" \
  "$signed_directory" \
  "$release_tag" \
  "$(release_version_from_tag "$release_tag")" \
  "$expected_team" \
  "$expected_fingerprint" <<'PY'
import hashlib
import json
import pathlib
import plistlib
import subprocess
import sys

output_path, signed_root, tag, version, team, fingerprint = sys.argv[1:]
root = pathlib.Path(signed_root)

definitions = [
    (
        "xpc-service",
        "LokiBrief.app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc",
        "LokiBrief.app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader",
    ),
    (
        "xpc-service",
        "LokiBrief.app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc",
        "LokiBrief.app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer",
    ),
    (
        "helper-application",
        "LokiBrief.app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app",
        "LokiBrief.app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater",
    ),
    (
        "command-line-helper",
        "LokiBrief.app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate",
        "LokiBrief.app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate",
    ),
    (
        "framework",
        "LokiBrief.app/Contents/Frameworks/Sparkle.framework",
        "LokiBrief.app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle",
    ),
    (
        "application",
        "LokiBrief.app",
        "LokiBrief.app/Contents/MacOS/LokiBrief",
    ),
]

def code_details(path):
    result = subprocess.run(
        ["codesign", "-dv", "--verbose=4", str(path)],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return result.stderr.splitlines()

def detail_value(lines, prefix):
    values = [line[len(prefix):] for line in lines if line.startswith(prefix)]
    if not values:
        raise SystemExit(f"missing code-signing detail: {prefix}")
    return values[0]

def entitlements(path):
    result = subprocess.run(
        ["codesign", "-d", "--entitlements", ":-", str(path)],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    return {} if not result.stdout else plistlib.loads(result.stdout)

def architectures(path):
    result = subprocess.run(
        ["lipo", "-archs", str(path)],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return sorted(result.stdout.split())

objects = []
for kind, code_relative, executable_relative in definitions:
    code_path = root / code_relative
    executable_path = root / executable_relative
    details = code_details(code_path)
    objects.append({
        "architectures": architectures(executable_path),
        "cdhash": detail_value(details, "CDHash="),
        "designatedRequirementValid": True,
        "entitlements": entitlements(code_path),
        "executablePath": executable_relative,
        "executableSha256": hashlib.sha256(executable_path.read_bytes()).hexdigest(),
        "hardenedRuntime": True,
        "identifier": detail_value(details, "Identifier="),
        "kind": kind,
        "path": code_relative,
        "secureTimestamp": True,
        "signatureValid": True,
        "teamIdVerified": True,
    })

app_details = code_details(root / "LokiBrief.app")
certificate_common_name = detail_value(app_details, "Authority=")
embedded_profile_path = root / "LokiBrief.app/Contents/embedded.provisionprofile"
profile_result = subprocess.run(
    ["security", "cms", "-D", "-i", str(embedded_profile_path)],
    check=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
)
profile = plistlib.loads(profile_result.stdout)
profile_expiration = profile["ExpirationDate"].strftime("%Y-%m-%dT%H:%M:%SZ")
record = {
    "app": "LokiBrief.app",
    "certificateCommonName": certificate_common_name,
    "certificateFingerprintSha1": fingerprint,
    "certificateType": "Developer ID Application",
    "cdhash": objects[-1]["cdhash"],
    "codeObjects": objects,
    "designatedRequirementsValid": True,
    "exactCodeInventory": True,
    "exactEntitlements": True,
    "hardenedRuntime": True,
    "nestedCodeObjectCount": 5,
    "provisioningProfile": {
        "applicationIdentifier": profile["Entitlements"]["com.apple.application-identifier"],
        "embedded": True,
        "expiration": profile_expiration,
        "provisionsAllDevices": profile["ProvisionsAllDevices"],
        "sha256": hashlib.sha256(embedded_profile_path.read_bytes()).hexdigest(),
        "uuid": profile["UUID"],
    },
    "schemaVersion": 1,
    "secureTimestamp": True,
    "status": "developer-id-signed",
    "tag": tag,
    "teamId": team,
    "version": version,
}
encoded = json.dumps(record, indent=2, sort_keys=True) + "\n"
for forbidden in (str(root), "/Users/", "/home/", "C:\\Users\\"):
    if forbidden in encoded:
        raise SystemExit("code-signing record contains a private absolute path")
with open(output_path, "x", encoding="utf-8", newline="\n") as handle:
    handle.write(encoded)
PY
chmod 0644 "$signing_record"

printf '%s\n' "$signed_app"
printf '%s\n' "$signing_record"
