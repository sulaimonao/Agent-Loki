#!/bin/bash
set -euo pipefail

RELEASE_PROGRAM=package-source-release
release_script_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P)
# shellcheck source=release-common.sh
source "$release_script_dir/release-common.sh"

usage() {
  cat >&2 <<'USAGE'
usage: scripts/package-source-release.sh --output-dir ABSOLUTE_DIR --tag TAG [--dry-run]
       scripts/package-source-release.sh ABSOLUTE_OUTPUT_DIR [GIT_REF] [VERSION]

The option form emits the canonical Agent-Loki-vX.Y.Z-rc.N-source.tar.gz name.
The positional RC1-compatible form retains the historical lowercase filename,
but still derives and verifies VERSION from the matching annotated tag.
USAGE
}

output_dir_input=
release_tag=
legacy_ref=
legacy_version=
legacy_mode=false
dry_run=false

if [[ $# -gt 0 && "$1" != --* ]]; then
  legacy_mode=true
  if [[ $# -lt 1 || $# -gt 3 ]]; then
    usage
    exit 2
  fi
  output_dir_input=$1
  legacy_ref=${2:-HEAD}
  legacy_version=${3:-}
else
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --output-dir)
        release_require_value "$1" "${2-}"
        output_dir_input=$2
        shift 2
        ;;
      --tag)
        release_require_value "$1" "${2-}"
        release_tag=$2
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
fi

[[ -n "$output_dir_input" ]] || {
  usage
  release_usage_error "output directory is required"
}

release_root=$(release_repository_root_from_script "$release_script_dir")
if [[ "$legacy_mode" == true ]]; then
  legacy_commit=$(git -C "$release_root" rev-parse --verify "$legacy_ref^{commit}" 2>/dev/null) ||
    release_usage_error "legacy Git ref is not a commit: $legacy_ref"
  if [[ -n "$legacy_version" ]]; then
    release_tag="v$legacy_version"
  else
    release_tags_at_commit=$(git -C "$release_root" tag --points-at "$legacy_commit" |
      grep -E '^v[0-9]+\.[0-9]+\.[0-9]+-rc\.[0-9]+$' || true)
    [[ -n "$release_tags_at_commit" && "$(printf '%s\n' "$release_tags_at_commit" | wc -l | tr -d ' ')" == 1 ]] ||
      release_usage_error "legacy invocation requires VERSION when the ref does not identify exactly one RC tag"
    release_tag=$release_tags_at_commit
  fi
  release_validate_tag "$release_tag"
  tag_commit=$(git -C "$release_root" rev-parse "refs/tags/$release_tag^{commit}" 2>/dev/null || true)
  [[ "$legacy_commit" == "$tag_commit" ]] ||
    release_die "legacy ref does not match annotated release tag $release_tag"
  if [[ -n "$legacy_version" && "$legacy_version" != "$(release_version_from_tag "$release_tag")" ]]; then
    release_die "legacy VERSION does not match the release tag"
  fi
else
  [[ -n "$release_tag" ]] || {
    usage
    release_usage_error "--tag is required"
  }
fi

release_assert_repo_clean_tag "$release_root" "$release_tag"
release_assert_release_metadata "$release_root" "$release_tag"
output_dir=$(release_resolve_existing_directory "$output_dir_input")
release_assert_artifact_root "$release_root" "$output_dir"

release_version=$(release_version_from_tag "$release_tag")
if [[ "$legacy_mode" == true ]]; then
  archive_name="agent-loki-v${release_version}-source.tar.gz"
  archive_prefix="agent-loki-v${release_version}"
else
  archive_name="$(release_asset_prefix "$release_tag")-source.tar.gz"
  archive_prefix=$(release_asset_prefix "$release_tag")
fi
archive_path="$output_dir/$archive_name"
release_assert_output_absent "$archive_path"
release_commit=$(git -C "$release_root" rev-parse "refs/tags/$release_tag^{commit}")

required_in_ref='LICENSE
NOTICE
THIRD_PARTY_NOTICES.md
README.md
CHANGELOG.md
ROADMAP.md
CONTRIBUTING.md
CODE_OF_CONDUCT.md
SUPPORT.md
SECURITY.md
PRIVACY.md
docs/ARCHITECTURE.md
docs/CONNECTORS.md
docs/BUILDING.md
docs/TESTING.md
docs/RELEASING.md
docs/PUBLICATION_CHECKLIST.md
docs/SECURITY_REVIEW.md
docs/OPEN_SOURCE_RELEASE_STATUS.md
docs/AGENT_LOKI_V1_PROVENANCE.md
scripts/verify-release.sh
scripts/check-secrets.sh
scripts/release-common.sh
scripts/build-release-app.sh
scripts/sign-release-app.sh
scripts/create-dmg.sh
scripts/notarize-dmg.sh
scripts/verify-dmg.sh
scripts/package-source-release.sh
scripts/generate-sbom.sh
scripts/generate-checksums.sh
scripts/prepare-github-release.sh
scripts/verify-publication-repo.sh
scripts/run-disposable-app-smoke.sh
scripts/generate-dependency-inventory.sh'

while IFS= read -r release_path; do
  git -C "$release_root" cat-file -e "${release_commit}:${release_path}" 2>/dev/null ||
    release_die "tag is missing required path: $release_path"
done <<<"$required_in_ref"

forbidden_ref_paths=$(
  git -C "$release_root" ls-tree -r --name-only "$release_commit" |
    grep -E '(^|/)(docs/session_logs|node_modules|dist|DerivedData|release-artifacts|release-output)(/|$)|\.(xcresult|xcarchive|dmg|pkg|p12|pfx|mobileprovision|sqlite|sqlite3|db|ndjson)$' || true
)
[[ -z "$forbidden_ref_paths" ]] || {
  printf 'package-source-release: forbidden paths in tag:\n%s\n' "$forbidden_ref_paths" >&2
  exit 1
}

if [[ "$dry_run" == true ]]; then
  release_print_command git -C "$release_root" archive --format=tar --prefix="$archive_prefix/" "$release_commit"
  printf 'DRY-RUN: gzip -n, extract into a task-owned directory, and run scripts/verify-release.sh\n'
  printf 'package-source-release: output=%s\n' "$archive_name"
  printf 'package-source-release: execution=not-requested\n'
  exit 0
fi

for required_command in git gzip grep tar; do
  release_require_command "$required_command"
done

temporary_archive=$(mktemp "$output_dir/.${archive_name}.XXXXXX")
verification_root=
cleanup_package() {
  rm -f "$temporary_archive"
  if [[ -n "$verification_root" && -d "$verification_root" ]]; then
    case "$verification_root/" in
      "$output_dir"/.agent-loki-source-verify.*/*) rm -rf "$verification_root" ;;
      *) printf 'package-source-release: refusing unsafe cleanup target\n' >&2 ;;
    esac
  fi
}
trap cleanup_package EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

umask 077
git -C "$release_root" archive --format=tar --prefix="$archive_prefix/" "$release_commit" |
  gzip -n >"$temporary_archive"

if tar -tzf "$temporary_archive" |
   grep -E '(^|/)(\.git|docs/session_logs|node_modules|dist|DerivedData|release-artifacts|release-output)(/|$)' >/dev/null; then
  release_die "archive contains a forbidden path"
fi

verification_root=$(mktemp -d "$output_dir/.agent-loki-source-verify.XXXXXX")
tar -xzf "$temporary_archive" -C "$verification_root"
verification_tree="$verification_root/$archive_prefix"
[[ -d "$verification_tree" ]] || release_die "extracted verification tree is missing"
(
  cd "$verification_tree"
  scripts/verify-release.sh
) || release_die "extracted source verification failed"

rm -rf "$verification_root"
verification_root=
chmod 0644 "$temporary_archive"
mv "$temporary_archive" "$archive_path"
trap - EXIT HUP INT TERM
printf '%s\n' "$archive_path"
