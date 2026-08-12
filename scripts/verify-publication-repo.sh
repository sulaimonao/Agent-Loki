#!/bin/bash
set -euo pipefail

RELEASE_PROGRAM=verify-publication-repo
release_script_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P)
# shellcheck source=release-common.sh
source "$release_script_dir/release-common.sh"

usage() {
  cat >&2 <<'USAGE'
usage: scripts/verify-publication-repo.sh --tag TAG \
  --canonical-repo ABSOLUTE_DIR --publication-repo ABSOLUTE_DIR \
  --publication-author-name PUBLIC_NAME \
  --publication-author-email PUBLIC_EMAIL --output ABSOLUTE_JSON \
  [--expected-origin HTTPS_GITHUB_URL] [--dry-run]

Verifies zero-difference tagged trees, exactly the main and release-tag refs, no
extra reflog identity, no unreachable/dangling object, a small clean history,
no inherited object store, no forbidden payload, and no secret/private path
finding in any reachable public object. By default, the publication repository
must have no remote. With --expected-origin, it must have exactly one remote
named origin whose fetch and push URLs exactly match the bounded HTTPS GitHub
URL. The verifier never creates, changes, or contacts a remote repository.
USAGE
}

release_tag=
canonical_repo_input=
publication_repo_input=
publication_author_name=
publication_author_email=
output_input=
expected_origin=
dry_run=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      release_require_value "$1" "${2-}"
      release_tag=$2
      shift 2
      ;;
    --canonical-repo)
      release_require_value "$1" "${2-}"
      canonical_repo_input=$2
      shift 2
      ;;
    --publication-repo)
      release_require_value "$1" "${2-}"
      publication_repo_input=$2
      shift 2
      ;;
    --publication-author-name)
      release_require_value "$1" "${2-}"
      publication_author_name=$2
      shift 2
      ;;
    --publication-author-email)
      release_require_value "$1" "${2-}"
      publication_author_email=$2
      shift 2
      ;;
    --output)
      release_require_value "$1" "${2-}"
      output_input=$2
      shift 2
      ;;
    --expected-origin)
      release_require_value "$1" "${2-}"
      expected_origin=$2
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

[[ -n "$release_tag" && -n "$canonical_repo_input" && -n "$publication_repo_input" &&
   -n "$publication_author_name" && -n "$publication_author_email" && -n "$output_input" ]] || {
  usage
  release_usage_error "tag, both repositories, publication identity, and output are required"
}
release_validate_text "publication author name" "$publication_author_name"
release_validate_text "publication author email" "$publication_author_email"
publication_name_pattern="^[A-Za-z0-9][A-Za-z0-9._ '-]{0,99}$"
[[ "$publication_author_name" =~ $publication_name_pattern ]] ||
  release_usage_error "publication author name must be a bounded public ASCII identity"
[[ "$publication_author_email" =~ ^[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] ||
  release_usage_error "publication author email must be a public email-shaped identity"
if [[ -n "$expected_origin" ]]; then
  release_validate_text "expected origin" "$expected_origin"
  expected_origin_byte_count=$(LC_ALL=C printf '%s' "$expected_origin" | wc -c | tr -d ' ')
  [[ "$expected_origin_byte_count" -ge 1 && "$expected_origin_byte_count" -le 256 ]] ||
    release_usage_error "expected origin must be between 1 and 256 ASCII bytes"
  expected_origin_pattern='^https://github\.com/[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?/[A-Za-z0-9]([A-Za-z0-9._-]{0,98}[A-Za-z0-9._-])?(\.git)?$'
  [[ "$expected_origin" =~ $expected_origin_pattern ]] ||
    release_usage_error "expected origin must be a bounded HTTPS GitHub repository URL"
fi

for git_override in \
  GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_INDEX_FILE GIT_NAMESPACE \
  GIT_QUARANTINE_PATH GIT_REPLACE_REF_BASE
do
  [[ -z "${!git_override-}" ]] ||
    release_die "Git repository override is forbidden: $git_override"
done

script_repository=$(release_repository_root_from_script "$release_script_dir")
canonical_repo=$(release_resolve_existing_directory "$canonical_repo_input")
publication_repo=$(release_resolve_existing_directory "$publication_repo_input")
[[ "$canonical_repo" != "$publication_repo" ]] ||
  release_usage_error "canonical and publication repositories must be different directories"
[[ "$script_repository" == "$canonical_repo" || "$script_repository" == "$publication_repo" ]] ||
  release_usage_error "run the verifier from one of the repositories being compared"

release_assert_repo_clean_tag "$canonical_repo" "$release_tag"
release_assert_repo_clean_tag "$publication_repo" "$release_tag"
release_assert_release_metadata "$canonical_repo" "$release_tag"
release_assert_release_metadata "$publication_repo" "$release_tag"

[[ "$(git -C "$publication_repo" branch --show-current)" == main ]] ||
  release_die "publication repository must be on branch main"
configured_remotes=$(git -C "$publication_repo" remote | LC_ALL=C sort)
configured_remote_count=$(printf '%s\n' "$configured_remotes" |
  sed '/^$/d' | wc -l | tr -d ' ')
origin_fetch_urls=
origin_push_urls=
origin_configured_fetch_urls=
origin_configured_push_urls=
if [[ -z "$expected_origin" ]]; then
  [[ "$configured_remote_count" == 0 ]] ||
    release_die "publication repository must have no configured remotes unless --expected-origin is supplied"
else
  [[ "$configured_remote_count" == 1 && "$configured_remotes" == origin ]] ||
    release_die "publication repository must have exactly one configured remote named origin"
  origin_configured_fetch_urls=$(git -C "$publication_repo" config --local --get-all remote.origin.url || true)
  origin_configured_push_urls=$(git -C "$publication_repo" config --local --get-all remote.origin.pushurl || true)
  origin_fetch_urls=$(git -C "$publication_repo" remote get-url --all origin) ||
    release_die "unable to read the publication origin fetch URL"
  origin_push_urls=$(git -C "$publication_repo" remote get-url --push --all origin) ||
    release_die "unable to read the publication origin push URL"
  [[ "$origin_configured_fetch_urls" == "$expected_origin" ]] ||
    release_die "publication origin must contain exactly one configured fetch URL matching --expected-origin"
  [[ -z "$origin_configured_push_urls" || "$origin_configured_push_urls" == "$expected_origin" ]] ||
    release_die "publication origin configured push URL does not exactly match --expected-origin"
  [[ "$origin_fetch_urls" == "$expected_origin" ]] ||
    release_die "publication origin fetch URL does not exactly match --expected-origin"
  [[ "$origin_push_urls" == "$expected_origin" ]] ||
    release_die "publication origin push URL does not exactly match --expected-origin"
fi

publication_git_dir=$(git -C "$publication_repo" rev-parse --git-dir)
if [[ "$publication_git_dir" != /* ]]; then
  publication_git_dir="$publication_repo/$publication_git_dir"
fi
publication_git_dir=$(release_resolve_existing_directory "$publication_git_dir")
publication_common_dir=$(git -C "$publication_repo" rev-parse --git-common-dir)
if [[ "$publication_common_dir" != /* ]]; then
  publication_common_dir="$publication_repo/$publication_common_dir"
fi
publication_common_dir=$(release_resolve_existing_directory "$publication_common_dir")
[[ -d "$publication_repo/.git" && ! -L "$publication_repo/.git" ]] ||
  release_die "publication repository must have its own standalone .git directory"
publication_own_git_dir=$(release_resolve_existing_directory "$publication_repo/.git")
[[ "$publication_git_dir" == "$publication_common_dir" &&
   "$publication_git_dir" == "$publication_own_git_dir" ]] ||
  release_die "publication repository must not be a linked worktree or inherit a common Git directory"
[[ ! -s "$publication_git_dir/objects/info/alternates" ]] ||
  release_die "publication repository uses an alternate object database"
[[ ! -e "$publication_git_dir/info/grafts" ]] ||
  release_die "publication repository contains grafts"
[[ ! -e "$publication_git_dir/shallow" ]] ||
  release_die "publication repository is shallow"
[[ -z "$(git -C "$publication_repo" replace -l)" ]] ||
  release_die "publication repository contains replace refs"
[[ ! -e "$publication_repo/.gitmodules" ]] ||
  release_die "publication repository must not contain submodules"

all_refs=$(git -C "$publication_repo" for-each-ref --format='%(refname)' |
  LC_ALL=C sort)
expected_refs=$(printf '%s\n' "refs/heads/main" "refs/tags/$release_tag" |
  LC_ALL=C sort)
[[ "$all_refs" == "$expected_refs" ]] || {
  printf 'verify-publication-repo: refs must be exactly main and %s:\n%s\n' \
    "$release_tag" "${all_refs:-<none>}" >&2
  exit 1
}
ref_count=$(printf '%s\n' "$all_refs" | sed '/^$/d' | wc -l | tr -d ' ')

canonical_commit=$(git -C "$canonical_repo" rev-parse "refs/tags/$release_tag^{commit}")
publication_commit=$(git -C "$publication_repo" rev-parse "refs/tags/$release_tag^{commit}")
canonical_tree=$(git -C "$canonical_repo" rev-parse "refs/tags/$release_tag^{tree}")
publication_tree=$(git -C "$publication_repo" rev-parse "refs/tags/$release_tag^{tree}")
canonical_tag_object=$(git -C "$canonical_repo" rev-parse "refs/tags/$release_tag")
publication_tag_object=$(git -C "$publication_repo" rev-parse "refs/tags/$release_tag")
publication_main_commit=$(git -C "$publication_repo" rev-parse refs/heads/main)
[[ "$canonical_tree" == "$publication_tree" ]] ||
  release_die "publication tagged tree differs from the canonical tagged tree"
[[ "$publication_main_commit" == "$publication_commit" ]] ||
  release_die "publication main does not point to the release tag commit"

assert_publication_refs_unchanged() {
  [[ "$(git -C "$canonical_repo" rev-parse "refs/tags/$release_tag")" == "$canonical_tag_object" &&
     "$(git -C "$canonical_repo" rev-parse "refs/tags/$release_tag^{commit}")" == "$canonical_commit" &&
     "$(git -C "$canonical_repo" rev-parse "refs/tags/$release_tag^{tree}")" == "$canonical_tree" ]] ||
    release_die "canonical annotated tag identity changed during verification"
  [[ "$(git -C "$publication_repo" rev-parse "refs/tags/$release_tag")" == "$publication_tag_object" &&
     "$(git -C "$publication_repo" rev-parse "refs/tags/$release_tag^{commit}")" == "$publication_commit" &&
     "$(git -C "$publication_repo" rev-parse "refs/tags/$release_tag^{tree}")" == "$publication_tree" &&
     "$(git -C "$publication_repo" rev-parse refs/heads/main)" == "$publication_main_commit" ]] ||
    release_die "publication annotated tag or main identity changed during verification"
  [[ "$(git -C "$publication_repo" for-each-ref --format='%(refname)' | LC_ALL=C sort)" == "$all_refs" ]] ||
    release_die "publication ref set changed during verification"
  [[ "$(git -C "$publication_repo" remote | LC_ALL=C sort)" == "$configured_remotes" ]] ||
    release_die "publication remote set changed during verification"
  if [[ -n "$expected_origin" ]]; then
    [[ "$(git -C "$publication_repo" config --local --get-all remote.origin.url || true)" == "$origin_configured_fetch_urls" &&
       "$(git -C "$publication_repo" config --local --get-all remote.origin.pushurl || true)" == "$origin_configured_push_urls" &&
       "$(git -C "$publication_repo" remote get-url --all origin)" == "$origin_fetch_urls" &&
       "$(git -C "$publication_repo" remote get-url --push --all origin)" == "$origin_push_urls" ]] ||
      release_die "publication origin URLs changed during verification"
  fi
}

reachable_objects=$(git -C "$publication_repo" rev-list --objects --all |
  awk '{print $1}' | LC_ALL=C sort -u)
reachable_object_count=$(printf '%s\n' "$reachable_objects" |
  sed '/^$/d' | wc -l | tr -d ' ')
printf '%s\n' "$reachable_objects" | grep -Fx "$publication_tag_object" >/dev/null ||
  release_die "annotated publication tag object is not reachable from the allowed refs"
reflog_identities=$(git -C "$publication_repo" reflog show --all --format='%H' |
  sed '/^$/d' | LC_ALL=C sort -u)
reflog_identity_count=$(printf '%s\n' "$reflog_identities" |
  sed '/^$/d' | wc -l | tr -d ' ')
extra_reflog_identities=$(
  while IFS= read -r identity; do
    [[ -z "$identity" ]] && continue
    printf '%s\n' "$reachable_objects" | grep -Fx "$identity" >/dev/null ||
      printf '%s\n' "$identity"
  done <<<"$reflog_identities"
)
[[ -z "$extra_reflog_identities" ]] || {
  printf 'verify-publication-repo: reflogs contain identities outside the allowed refs:\n%s\n' \
    "$extra_reflog_identities" >&2
  exit 1
}

commit_count=$(git -C "$publication_repo" rev-list --count "$release_tag")
root_count=$(git -C "$publication_repo" rev-list --max-parents=0 "$release_tag" | wc -l | tr -d ' ')
merge_count=$(git -C "$publication_repo" rev-list --min-parents=2 "$release_tag" | wc -l | tr -d ' ')
[[ "$root_count" == 1 ]] || release_die "publication history must contain exactly one root commit"
[[ "$merge_count" == 0 ]] || release_die "publication history must not contain merge commits"
[[ "$commit_count" -ge 1 && "$commit_count" -le 3 ]] ||
  release_die "publication history must contain only one small clean commit series (found $commit_count commits)"

expected_publication_identity="$publication_author_name <$publication_author_email>"
publication_identity_findings=$(
  git -C "$publication_repo" rev-list "$release_tag" |
    while IFS= read -r commit_id; do
      author_identity=$(git -C "$publication_repo" show -s --format='%an <%ae>' "$commit_id")
      committer_identity=$(git -C "$publication_repo" show -s --format='%cn <%ce>' "$commit_id")
      [[ "$author_identity" == "$expected_publication_identity" ]] ||
        printf '%s:author-identity-mismatch\n' "$commit_id"
      [[ "$committer_identity" == "$expected_publication_identity" ]] ||
        printf '%s:committer-identity-mismatch\n' "$commit_id"
    done
)
tagger_identity=$(git -C "$publication_repo" for-each-ref \
  --format='%(taggername)|%(taggeremail)' "refs/tags/$release_tag")
[[ "$tagger_identity" == "$publication_author_name|<$publication_author_email>" ]] ||
  publication_identity_findings="${publication_identity_findings}${publication_identity_findings:+$'\n'}tag:tagger-identity-mismatch"
[[ -z "$publication_identity_findings" ]] || {
  printf 'verify-publication-repo: commit/tag identities differ from the explicit public identity:\n%s\n' \
    "$publication_identity_findings" >&2
  exit 1
}
publication_identity_count=$((commit_count * 2 + 1))

gitlinks=$(git -C "$publication_repo" ls-tree -r "$release_tag" | awk '$1 == "160000" {print $4}')
[[ -z "$gitlinks" ]] || release_die "publication tree contains Git links/submodules"
forbidden_paths=$(git -C "$publication_repo" ls-tree -r --name-only "$release_tag" |
  grep -E '(^|/)(docs/session_logs|node_modules|dist|DerivedData|release-artifacts|release-output)(/|$)|\.(xcresult|xcarchive|dmg|pkg|p12|pfx|mobileprovision|sqlite|sqlite3|db|ndjson)$' || true)
[[ -z "$forbidden_paths" ]] || {
  printf 'verify-publication-repo: forbidden public paths:\n%s\n' "$forbidden_paths" >&2
  exit 1
}

local_user_name=$(id -un)
historical_path_counts=$(
  git -C "$publication_repo" rev-list --all |
    while IFS= read -r history_commit; do
      git -C "$publication_repo" diff-tree --root --no-commit-id --no-renames \
        --name-only -r -z "$history_commit"
    done |
    PUBLICATION_LOCAL_USER=$local_user_name \
    PUBLICATION_PUBLIC_NAME=$publication_author_name \
    PUBLICATION_PUBLIC_EMAIL=$publication_author_email \
    perl -0ne '
      chomp;
      next if $_ eq "";
      $all{$_} = 1;
      my $approved_empty_runtime_log_placeholder = $_ eq "data/logs/.gitkeep";
      if (!$approved_empty_runtime_log_placeholder
          && (m{(?:^|/)(?:docs/session_logs|node_modules|dist|DerivedData|release-artifacts|release-output|proof|proofs|results|result-bundles|logs)(?:/|$)}
              || /\.(?:xcresult|xcarchive|dmg|pkg|p12|pfx|mobileprovision|sqlite|sqlite3|db|ndjson|log|trace)\z/i)) {
        $forbidden{$_} = 1;
      }
      my $local_user = $ENV{"PUBLICATION_LOCAL_USER"} // "";
      my $public_name = $ENV{"PUBLICATION_PUBLIC_NAME"} // "";
      my $public_email = $ENV{"PUBLICATION_PUBLIC_EMAIL"} // "";
      my $private = 0;
      $private = 1 if m{/(?:Users|home)/[^/\s`"<>]+(?:/|$)};
      $private = 1 if m{[A-Za-z]:[\\/]Users[\\/][^\\/\s`"<>]+(?:[\\/]|$)}i;
      my $identity_text = $_;
      $identity_text =~ s/\Q$public_email\E//ig if $public_email ne "";
      my $approved_app_icon_scale_name = $identity_text =~
        m{\Amacos/LokiBrief/LokiBrief/Assets\.xcassets/AppIcon\.appiconset/AppIcon-\d+x\d+\@2x\.png\z};
      $private = 1 if !$approved_app_icon_scale_name
        && $identity_text =~ /[A-Za-z0-9._%+-]+\@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/;
      $private = 1 if /(?:xox[baprs]-[A-Za-z0-9-]{10,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}|sk_live_[0-9A-Za-z]{16,}|glpat-[0-9A-Za-z_-]{16,}|npm_[0-9A-Za-z]{20,})/;
      $private = 1 if length($local_user) >= 3
        && index(lc($public_name), lc($local_user)) < 0
        && /(?<![A-Za-z0-9])\Q$local_user\E(?![A-Za-z0-9])/i;
      $private_names{$_} = 1 if $private;
      END {
        print scalar(keys %all), "|", scalar(keys %forbidden), "|",
          scalar(keys %private_names);
      }
    '
)
historical_path_count=${historical_path_counts%%|*}
historical_path_remainder=${historical_path_counts#*|}
historical_forbidden_path_count=${historical_path_remainder%%|*}
historical_private_path_count=${historical_path_counts##*|}
[[ "$historical_path_count" =~ ^[0-9]+$ && "$historical_forbidden_path_count" =~ ^[0-9]+$ &&
   "$historical_private_path_count" =~ ^[0-9]+$ ]] ||
  release_die "unable to count historical public paths"
[[ "$historical_forbidden_path_count" == 0 ]] ||
  release_die "forbidden payload paths exist in reachable public history (count: $historical_forbidden_path_count)"
[[ "$historical_private_path_count" == 0 ]] ||
  release_die "private/secret-shaped path names exist in reachable public history (count: $historical_private_path_count)"

if [[ "$dry_run" == true ]]; then
  printf 'DRY-RUN: run git fsck --full --unreachable --no-reflogs and reject every finding\n'
  printf 'DRY-RUN: scan reachable blobs/commits/tags and historical tree paths for secret/private classifications\n'
  printf 'DRY-RUN: run scripts/check-secrets.sh --history and scripts/verify-release.sh in the publication repository\n'
  printf 'verify-publication-repo: tree=%s tag-object=%s commits=%s refs=%s remotes=%s identities=%s reflog-identities=%s reachable-objects=%s historical-paths=%s execution=not-requested\n' \
    "$publication_tree" "$publication_tag_object" "$commit_count" "$ref_count" \
    "$configured_remote_count" "$publication_identity_count" "$reflog_identity_count" \
    "$reachable_object_count" "$historical_path_count"
  assert_publication_refs_unchanged
  exit 0
fi

fsck_output=
if ! fsck_output=$(git -C "$publication_repo" fsck --full --unreachable --no-reflogs --no-progress 2>&1); then
  printf 'verify-publication-repo: git fsck failed:\n%s\n' "$fsck_output" >&2
  exit 1
fi
unreachable_object_count=$(printf '%s\n' "$fsck_output" |
  grep -Ec '^(unreachable|dangling) ' || true)
[[ "$unreachable_object_count" == 0 && -z "$fsck_output" ]] || {
  printf 'verify-publication-repo: unreachable, dangling, or other fsck findings are forbidden:\n%s\n' \
    "$fsck_output" >&2
  exit 1
}

private_path_findings=$(
  git -C "$publication_repo" rev-list --objects --all |
    while IFS=' ' read -r object_id object_path; do
      object_type=$(git -C "$publication_repo" cat-file -t "$object_id" 2>/dev/null) || continue
      [[ "$object_type" == blob || "$object_type" == commit || "$object_type" == tag ]] || continue
      git -C "$publication_repo" cat-file "$object_type" "$object_id" |
        PUBLICATION_LOCAL_USER=$local_user_name \
        PUBLICATION_PUBLIC_NAME=$publication_author_name \
        PUBLICATION_PUBLIC_EMAIL=$publication_author_email \
        perl -0777 -ne '
          my @classes;
          push @classes, "absolute-macos-user-path" if m{/(?:Users)/[^/\s`"<>]+(?:/|$)};
          push @classes, "absolute-linux-user-path" if m{/(?:home)/[^/\s`"<>]+(?:/|$)};
          push @classes, "absolute-windows-user-path" if m{[A-Za-z]:[\\/]Users[\\/][^\\/\s`"<>]+(?:[\\/]|$)}i;
          my $local_user = $ENV{"PUBLICATION_LOCAL_USER"} // "";
          my $public_name = $ENV{"PUBLICATION_PUBLIC_NAME"} // "";
          my $public_email = $ENV{"PUBLICATION_PUBLIC_EMAIL"} // "";
          push @classes, "local-user-name"
            if length($local_user) >= 3
              && index(lc($public_name), lc($local_user)) < 0
              && index(lc($public_email), lc($local_user)) < 0
              && /(?<![A-Za-z0-9])\Q$local_user\E(?![A-Za-z0-9])/i;
          print "$_\n" for @classes;
        ' |
        while IFS= read -r finding_class; do
          printf '%s:%s:%s\n' "$object_id" "${object_path:-<$object_type-object>}" "$finding_class"
        done
    done
)
[[ -z "$private_path_findings" ]] || {
  printf 'verify-publication-repo: private path classifications found in reachable public history:\n%s\n' "$private_path_findings" >&2
  exit 1
}

metadata_message_findings=$(
  git -C "$publication_repo" rev-list --objects --all |
    while IFS=' ' read -r object_id object_path; do
      object_type=$(git -C "$publication_repo" cat-file -t "$object_id" 2>/dev/null) || continue
      [[ "$object_type" == commit || "$object_type" == tag ]] || continue
      git -C "$publication_repo" cat-file "$object_type" "$object_id" |
        sed '1,/^$/d' |
        PUBLICATION_LOCAL_USER=$local_user_name \
        PUBLICATION_PUBLIC_NAME=$publication_author_name \
        PUBLICATION_PUBLIC_EMAIL=$publication_author_email \
        perl -0777 -ne '
          my @classes;
          my $identity_text = $_;
          my $public_email = $ENV{"PUBLICATION_PUBLIC_EMAIL"} // "";
          $identity_text =~ s/\Q$public_email\E//ig if $public_email ne "";
          push @classes, "email-address-in-message"
            if $identity_text =~ /[A-Za-z0-9._%+-]+\@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/;
          my $local_user = $ENV{"PUBLICATION_LOCAL_USER"} // "";
          my $public_name = $ENV{"PUBLICATION_PUBLIC_NAME"} // "";
          push @classes, "local-user-name-in-message"
            if length($local_user) >= 3
              && index(lc($public_name), lc($local_user)) < 0
              && /(?<![A-Za-z0-9])\Q$local_user\E(?![A-Za-z0-9])/i;
          print "$_\n" for @classes;
        ' |
        while IFS= read -r finding_class; do
          printf '%s:<%s-message>:%s\n' "$object_id" "$object_type" "$finding_class"
        done
    done
)
[[ -z "$metadata_message_findings" ]] || {
  printf 'verify-publication-repo: private identity classifications found in commit/tag messages:\n%s\n' \
    "$metadata_message_findings" >&2
  exit 1
}

(
  cd "$publication_repo"
  scripts/check-secrets.sh --history
  if [[ -n "$expected_origin" ]]; then
    scripts/verify-release.sh --public-clean-history --expected-origin "$expected_origin"
  else
    scripts/verify-release.sh --public-clean-history
  fi
)
assert_publication_refs_unchanged

output=$(release_resolve_new_file "$output_input")
output_parent=$(release_resolve_existing_directory "$(dirname "$output")")
case "$output_parent/" in
  "$canonical_repo"/*|"$publication_repo"/*)
    release_usage_error "verification record must be outside both source repositories"
    ;;
esac
release_assert_expected_basename "$output" "$(release_asset_prefix "$release_tag")-PUBLICATION_REPO_VERIFICATION.json"
release_assert_output_absent "$output"
release_require_command python3

PUBLICATION_TAG=$release_tag \
PUBLICATION_VERSION=$(release_version_from_tag "$release_tag") \
PUBLICATION_CANONICAL_COMMIT=$canonical_commit \
PUBLICATION_CANONICAL_TAG_OBJECT=$canonical_tag_object \
PUBLICATION_COMMIT=$publication_commit \
PUBLICATION_MAIN_COMMIT=$publication_main_commit \
PUBLICATION_TREE=$publication_tree \
PUBLICATION_TAG_OBJECT=$publication_tag_object \
PUBLICATION_COMMIT_COUNT=$commit_count \
PUBLICATION_REF_COUNT=$ref_count \
PUBLICATION_IDENTITY_COUNT=$publication_identity_count \
PUBLICATION_AUTHOR_NAME=$publication_author_name \
PUBLICATION_AUTHOR_EMAIL=$publication_author_email \
PUBLICATION_REFLOG_IDENTITY_COUNT=$reflog_identity_count \
PUBLICATION_REACHABLE_OBJECT_COUNT=$reachable_object_count \
PUBLICATION_UNREACHABLE_OBJECT_COUNT=$unreachable_object_count \
PUBLICATION_HISTORICAL_PATH_COUNT=$historical_path_count \
PUBLICATION_HISTORICAL_FORBIDDEN_PATH_COUNT=$historical_forbidden_path_count \
PUBLICATION_HISTORICAL_PRIVATE_PATH_COUNT=$historical_private_path_count \
PUBLICATION_REMOTE_COUNT=$configured_remote_count \
PUBLICATION_EXPECTED_ORIGIN=$expected_origin \
python3 - "$output" <<'PY'
import json
import os
import sys

record = {
    "canonicalCommit": os.environ["PUBLICATION_CANONICAL_COMMIT"],
    "canonicalTagObject": os.environ["PUBLICATION_CANONICAL_TAG_OBJECT"],
    "commitCount": int(os.environ["PUBLICATION_COMMIT_COUNT"]),
    "expectedOrigin": os.environ["PUBLICATION_EXPECTED_ORIGIN"] or None,
    "historicalForbiddenPathCount": int(os.environ["PUBLICATION_HISTORICAL_FORBIDDEN_PATH_COUNT"]),
    "historicalPathCount": int(os.environ["PUBLICATION_HISTORICAL_PATH_COUNT"]),
    "historicalPrivatePathCount": int(os.environ["PUBLICATION_HISTORICAL_PRIVATE_PATH_COUNT"]),
    "historySecretScan": "passed",
    "identityRecordCount": int(os.environ["PUBLICATION_IDENTITY_COUNT"]),
    "metadataPrivacyScan": "passed",
    "privatePathScan": "passed",
    "publicationIdentity": {
        "email": os.environ["PUBLICATION_AUTHOR_EMAIL"],
        "name": os.environ["PUBLICATION_AUTHOR_NAME"],
    },
    "publicationCommit": os.environ["PUBLICATION_COMMIT"],
    "publicationMainCommit": os.environ["PUBLICATION_MAIN_COMMIT"],
    "publicationTagObject": os.environ["PUBLICATION_TAG_OBJECT"],
    "reachableObjectCount": int(os.environ["PUBLICATION_REACHABLE_OBJECT_COUNT"]),
    "refCount": int(os.environ["PUBLICATION_REF_COUNT"]),
    "reflogIdentityCount": int(os.environ["PUBLICATION_REFLOG_IDENTITY_COUNT"]),
    "releaseVerifier": "passed",
    "remoteCount": int(os.environ["PUBLICATION_REMOTE_COUNT"]),
    "repositoryFsck": "passed",
    "schemaVersion": 2,
    "status": "verified-clean-publication-repository",
    "tag": os.environ["PUBLICATION_TAG"],
    "tree": os.environ["PUBLICATION_TREE"],
    "treePathPrivacyScan": "passed",
    "treeEquivalent": True,
    "unreachableObjectCount": int(os.environ["PUBLICATION_UNREACHABLE_OBJECT_COUNT"]),
    "version": os.environ["PUBLICATION_VERSION"],
}
with open(sys.argv[1], "x", encoding="utf-8", newline="\n") as handle:
    json.dump(record, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
chmod 0644 "$output"
printf '%s\n' "$output"
