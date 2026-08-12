#!/bin/bash
set -euo pipefail

RELEASE_PROGRAM=generate-checksums
release_script_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P)
# shellcheck source=release-common.sh
source "$release_script_dir/release-common.sh"

usage() {
  cat >&2 <<'USAGE'
usage: scripts/generate-checksums.sh --tag TAG --artifact-root ABSOLUTE_DIR \
  --artifact ABSOLUTE_FILE [--artifact ABSOLUTE_FILE ...] [--dry-run]
       scripts/generate-checksums.sh OUTPUT_FILE ARTIFACT [ARTIFACT ...]

The option form emits Agent-Loki-TAG-SHA256SUMS.txt. The positional form is
retained for RC1 compatibility and derives the sole release tag at HEAD.
Artifacts must be direct children of the checksum directory so verification is
portable after upload or download.
USAGE
}

release_tag=
artifact_root_input=
checksum_output_input=
legacy_mode=false
dry_run=false
artifacts=()

if [[ $# -gt 0 && "$1" != --* ]]; then
  legacy_mode=true
  [[ $# -ge 2 ]] || {
    usage
    exit 2
  }
  checksum_output_input=$1
  shift
  while [[ $# -gt 0 ]]; do
    artifacts+=("$1")
    shift
  done
else
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
      --artifact)
        release_require_value "$1" "${2-}"
        artifacts+=("$2")
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

[[ ${#artifacts[@]} -gt 0 ]] || {
  usage
  release_usage_error "at least one artifact is required"
}

release_root=$(release_repository_root_from_script "$release_script_dir")
if [[ "$legacy_mode" == true ]]; then
  head_commit=$(git -C "$release_root" rev-parse HEAD)
  release_tags_at_head=$(git -C "$release_root" tag --points-at "$head_commit" |
    grep -E '^v[0-9]+\.[0-9]+\.[0-9]+-rc\.[0-9]+$' || true)
  [[ -n "$release_tags_at_head" && "$(printf '%s\n' "$release_tags_at_head" | wc -l | tr -d ' ')" == 1 ]] ||
    release_usage_error "legacy invocation requires exactly one RC tag at HEAD"
  release_tag=$release_tags_at_head
  checksum_output=$(release_resolve_new_file "$checksum_output_input")
  artifact_root=$(release_resolve_existing_directory "$(dirname "$checksum_output")")
else
  [[ -n "$release_tag" && -n "$artifact_root_input" ]] || {
    usage
    release_usage_error "--tag and --artifact-root are required"
  }
  artifact_root=$(release_resolve_existing_directory "$artifact_root_input")
  checksum_output="$artifact_root/$(release_asset_prefix "$release_tag")-SHA256SUMS.txt"
fi

release_assert_artifact_root "$release_root" "$artifact_root"
release_assert_repo_clean_tag "$release_root" "$release_tag"
release_assert_release_metadata "$release_root" "$release_tag"
if [[ "$legacy_mode" == false ]]; then
  release_assert_expected_basename "$checksum_output" "$(release_asset_prefix "$release_tag")-SHA256SUMS.txt"
fi
release_assert_output_absent "$checksum_output"

resolved_artifacts=()
artifact_names=()
for artifact_input in "${artifacts[@]}"; do
  release_validate_text "artifact path" "$artifact_input"
  artifact=$(release_assert_direct_child_file "$artifact_root" "$artifact_input")
  artifact_name=$(basename "$artifact")
  [[ "$artifact_name" != *' '* && "$artifact_name" != *$'\t'* ]] ||
    release_usage_error "artifact basename contains whitespace: $artifact_name"
  for ((existing_index = 0; existing_index < ${#artifact_names[@]}; existing_index++)); do
    [[ "$artifact_name" != "${artifact_names[$existing_index]}" ]] ||
      release_usage_error "duplicate artifact basename: $artifact_name"
  done
  resolved_artifacts+=("$artifact")
  artifact_names+=("$artifact_name")
done

if [[ "$dry_run" == true ]]; then
  printf 'DRY-RUN: hash %s payload(s), sort by basename, reproduce, compare, and verify all entries\n' "${#resolved_artifacts[@]}"
  printf 'generate-checksums: output=%s\n' "$(basename "$checksum_output")"
  printf 'generate-checksums: execution=not-requested\n'
  exit 0
fi

release_require_command cmp
release_require_command shasum
checksum_temp=$(mktemp "$artifact_root/.agent-loki-checksums.XXXXXX")
checksum_reproduction=$(mktemp "$artifact_root/.agent-loki-checksums-reproduction.XXXXXX")
cleanup_checksums() {
  rm -f "$checksum_temp" "$checksum_reproduction"
}
trap cleanup_checksums EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
umask 077

write_checksums() {
  local destination=$1
  local index
  : >"$destination"
  for ((index = 0; index < ${#resolved_artifacts[@]}; index++)); do
    digest=$(release_sha256 "${resolved_artifacts[$index]}")
    printf '%s  %s\n' "$digest" "${artifact_names[$index]}" >>"$destination"
  done
  LC_ALL=C sort -o "$destination" "$destination"
}

write_checksums "$checksum_temp"
write_checksums "$checksum_reproduction"
cmp -s "$checksum_temp" "$checksum_reproduction" ||
  release_die "checksum reproduction mismatch"
(
  cd "$artifact_root"
  shasum -a 256 -c "$checksum_temp" >/dev/null
)

chmod 0644 "$checksum_temp"
mv "$checksum_temp" "$checksum_output"
trap - EXIT HUP INT TERM
rm -f "$checksum_reproduction"
printf '%s\n' "$checksum_output"
