#!/bin/sh
set -eu

allow_dirty=false
public_clean_history=false
expected_public_origin=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --allow-dirty) allow_dirty=true ;;
    --public-clean-history) public_clean_history=true ;;
    --expected-origin)
      shift
      [ "$#" -gt 0 ] || {
        echo "verify-release: --expected-origin requires a value" >&2
        exit 2
      }
      expected_public_origin=$1
      ;;
    *)
      echo "usage: scripts/verify-release.sh [--allow-dirty | --public-clean-history [--expected-origin HTTPS_GITHUB_URL]]" >&2
      exit 2
      ;;
  esac
  shift
done
if [ "$allow_dirty" = true ] && [ "$public_clean_history" = true ]; then
  echo "verify-release: --public-clean-history requires a clean checkout" >&2
  exit 2
fi
if [ -n "$expected_public_origin" ] && [ "$public_clean_history" != true ]; then
  echo "verify-release: --expected-origin requires --public-clean-history" >&2
  exit 2
fi
if [ -n "$expected_public_origin" ]; then
  case "$expected_public_origin" in
    https://github.com/*/*.git) ;;
    *)
      echo "verify-release: --expected-origin must be an HTTPS GitHub repository URL ending in .git" >&2
      exit 2
      ;;
  esac
fi

release_script_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P) || exit 2
release_root=$(dirname "$release_script_dir")
release_has_git=false
if release_git_root=$(git -C "$release_root" rev-parse --show-toplevel 2>/dev/null); then
  release_root=$release_git_root
  release_has_git=true
fi
cd "$release_root"

current_source_version=$(sed -nE 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' package.json | sed -n '1p')
case "$current_source_version" in
  1.0.0-rc.*) ;;
  *)
    echo "verify-release: unsupported source version: $current_source_version" >&2
    exit 2
    ;;
esac
current_candidate_number=${current_source_version##*.}
case "$current_candidate_number" in
  ''|*[!0-9]*)
    echo "verify-release: invalid release-candidate number: $current_candidate_number" >&2
    exit 2
    ;;
esac
current_release_tag="v$current_source_version"
current_release_notes="docs/RELEASE_NOTES_1.0.0_RC${current_candidate_number}.md"

release_failed=0
fail() {
  echo "verify-release: ERROR: $*" >&2
  release_failed=1
}

required_paths='LICENSE
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
docs/RELEASE_NOTES_1.0.0_RC1.md
docs/RELEASE_NOTES_1.0.0_RC2.md
docs/ATTACHED_DATA_SOURCES.md
docs/PUBLICATION_CHECKLIST.md
docs/SECURITY_REVIEW.md
docs/OPEN_SOURCE_RELEASE_STATUS.md
docs/AGENT_LOKI_V1_PROVENANCE.md
docs/LOKI_BRIEF_RUNBOOK.md
macos/LokiBrief/Config/ExportOptions-DeveloperID.plist
macos/LokiBrief/Config/Signing.example.xcconfig
macos/LokiBrief/Config/Signing.xcconfig
macos/LokiBrief/Config/Slack.example.xcconfig
macos/LokiBrief/Config/Slack.xcconfig
macos/LokiBrief/Config/Updates.example.xcconfig
macos/LokiBrief/Config/Updates.xcconfig
macos/LokiBrief/LokiBrief.xcodeproj/project.pbxproj
macos/LokiBrief/LokiBrief/LokiBrief.entitlements
macos/LokiBrief/LokiBrief/Info.plist
.github/PULL_REQUEST_TEMPLATE.md
.github/ISSUE_TEMPLATE/bug_report.yml
.github/ISSUE_TEMPLATE/feature_request.yml
.github/ISSUE_TEMPLATE/connector_request.yml
.github/ISSUE_TEMPLATE/config.yml
.github/dependabot.yml
.github/release.yml
.github/workflows/fixture-ci.yml
scripts/verify-release.sh
scripts/check-secrets.sh
scripts/package-source-release.sh
scripts/run-disposable-app-smoke.sh
scripts/generate-checksums.sh
scripts/generate-dependency-inventory.sh
scripts/build-release-app.sh
scripts/sign-release-app.sh
scripts/create-dmg.sh
scripts/notarize-dmg.sh
scripts/verify-dmg.sh
scripts/generate-sbom.sh
scripts/prepare-github-release.sh
scripts/verify-publication-repo.sh'

missing_paths=$(
  printf '%s\n' "$required_paths" |
    while IFS= read -r release_path; do
      [ -f "$release_path" ] || echo "$release_path"
    done
)
if [ -n "$missing_paths" ]; then
  fail "missing required paths:\n$missing_paths"
fi
[ -f "$current_release_notes" ] || fail "missing current release notes: $current_release_notes"

if find docs/session_logs -type f -print -quit 2>/dev/null | grep -q .; then
  fail "docs/session_logs contains private proof artifacts"
fi

candidate_paths() {
  if [ "$release_has_git" = true ]; then
    git ls-files --cached --others --exclude-standard | LC_ALL=C sort -u
  else
    find . -type f -print | sed 's#^\./##'
  fi
}

classify_candidate_paths() {
  candidate_paths |
    while IFS= read -r release_path; do
      [ -e "$release_path" ] || continue
      case "$release_path" in
        docs/session_logs/*|node_modules/*|dist/*|DerivedData/*|.env|*/.env|.env.local|*/.env.local|*.xcresult|*.xcarchive|*.dmg|*.pkg|*.p12|*.pfx|*.mobileprovision|*.sqlite|*.sqlite3|*.db|*.ndjson)
          printf '%s\n' "$release_path"
          ;;
      esac
    done
}

forbidden_candidate_paths=$(classify_candidate_paths)
if [ -n "$forbidden_candidate_paths" ]; then
  fail "forbidden candidate paths:\n$forbidden_candidate_paths"
fi

private_path_findings=$(
  candidate_paths |
    while IFS= read -r release_path; do
      [ -f "$release_path" ] || continue
      perl -ne '
        if (-B $ARGV) { close ARGV if eof; next; }
        my @classes;
        push @classes, "absolute-macos-user-path"
          if m{/(?:Users)/[^/\s`"<>]+(?:/|$)};
        push @classes, "absolute-linux-user-path"
          if m{/(?:home)/[^/\s`"<>]+(?:/|$)};
        push @classes, "absolute-windows-user-path"
          if m{[A-Za-z]:[\\/]Users[\\/][^\\/\s`"<>]+(?:[\\/]|$)}i;
        for my $class (@classes) {
          print "$ARGV:$.:$class\n";
        }
        close ARGV if eof;
      ' "$release_path"
    done
)
if [ -n "$private_path_findings" ]; then
  fail "private absolute paths found:\n$private_path_findings"
fi

if ! grep -Eq 'v1\.0\.0-rc\.1' docs/RELEASE_NOTES_1.0.0_RC1.md; then
  fail "historical RC1 source release version is missing"
fi
for version_document in README.md docs/RELEASING.md "$current_release_notes"; do
  if ! grep -F "$current_release_tag" "$version_document" >/dev/null; then
    fail "$current_release_tag is missing from $version_document"
  fi
done

lock_source_version=$(sed -nE 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' package-lock.json | sed -n '1p')
[ "$lock_source_version" = "$current_source_version" ] ||
  fail "package-lock.json version does not match package.json"

if [ "$release_has_git" = true ]; then
  xctest_identifiers_from_worktree() {
    find macos/LokiBrief/LokiBriefTests -type f -name '*.swift' -print0 |
      xargs -0 perl -ne '
        if (/^[[:space:]]*(?:final[[:space:]]+)?class[[:space:]]+(\w+)[[:space:]]*:[^{]*\bXCTestCase\b/) {
          $suite = $1;
        } elsif (/^[[:space:]]*(?:(?:private|fileprivate|internal|public|open)[[:space:]]+)?extension[[:space:]]+(\w+)\b/) {
          $suite = $1;
        }
        if (/^[[:space:]]*func[[:space:]]+(test[A-Za-z0-9_]+)[[:space:]]*\(/) {
          print((defined $suite ? $suite : "__UNKNOWN__"), "/$1\n");
        }
        close ARGV if eof;
      ' |
      LC_ALL=C sort
  }

  xctest_identifiers_from_ref() {
    xctest_ref=$1
    git ls-tree -r --name-only "$xctest_ref" -- \
      macos/LokiBrief/LokiBriefTests |
      LC_ALL=C sort |
      while IFS= read -r xctest_path; do
        git show "$xctest_ref:$xctest_path" |
          perl -ne '
            if (/^[[:space:]]*(?:final[[:space:]]+)?class[[:space:]]+(\w+)[[:space:]]*:[^{]*\bXCTestCase\b/) {
              $suite = $1;
            } elsif (/^[[:space:]]*(?:(?:private|fileprivate|internal|public|open)[[:space:]]+)?extension[[:space:]]+(\w+)\b/) {
              $suite = $1;
            }
            if (/^[[:space:]]*func[[:space:]]+(test[A-Za-z0-9_]+)[[:space:]]*\(/) {
              print((defined $suite ? $suite : "__UNKNOWN__"), "/$1\n");
            }
          '
      done |
      LC_ALL=C sort
  }

  current_test_identifiers=$(
    xctest_identifiers_from_worktree
  )
  unknown_test_identifiers=$(printf '%s\n' "$current_test_identifiers" | grep '^__UNKNOWN__/' || true)
  if [ -n "$unknown_test_identifiers" ]; then
    fail "XCTest methods could not be bound to a test class:\n$unknown_test_identifiers"
  fi
  duplicate_test_identifiers=$(printf '%s\n' "$current_test_identifiers" | uniq -d)
  if [ -n "$duplicate_test_identifiers" ]; then
    fail "duplicate class-qualified XCTest identifiers:\n$duplicate_test_identifiers"
  fi
  if [ "$public_clean_history" = false ] &&
    git cat-file -e 'v1.0.0-rc.1^{commit}' 2>/dev/null; then
    baseline_test_identifiers=$(
      xctest_identifiers_from_ref v1.0.0-rc.1
    )
    removed_test_identifiers=$(
      {
        printf '%s\n' "$baseline_test_identifiers"
        printf '%s\n' '__CURRENT_TEST_IDENTIFIERS__'
        printf '%s\n' "$current_test_identifiers"
      } |
        awk '
          $0 == "__CURRENT_TEST_IDENTIFIERS__" { current = 1; next }
          !current { baseline[$0] = 1; next }
          current { delete baseline[$0] }
          END { for (identifier in baseline) print identifier }
        ' |
        LC_ALL=C sort
    )
    if [ -n "$removed_test_identifiers" ]; then
      fail "RC1 XCTest identifiers removed without an exact mapping:\n$removed_test_identifiers"
    fi
    new_test_identifiers=$(
      {
        printf '%s\n' "$current_test_identifiers"
        printf '%s\n' '__BASELINE_TEST_IDENTIFIERS__'
        printf '%s\n' "$baseline_test_identifiers"
      } |
        awk '
          $0 == "__BASELINE_TEST_IDENTIFIERS__" { baseline = 1; next }
          !baseline { current[$0] = 1; next }
          baseline { delete current[$0] }
          END { for (identifier in current) print identifier }
        ' |
        LC_ALL=C sort
    )
    baseline_test_count=$(printf '%s\n' "$baseline_test_identifiers" | sed '/^$/d' | wc -l | tr -d ' ')
    current_test_count=$(printf '%s\n' "$current_test_identifiers" | sed '/^$/d' | wc -l | tr -d ' ')
    new_test_count=$(printf '%s\n' "$new_test_identifiers" | sed '/^$/d' | wc -l | tr -d ' ')
    echo "verify-release: XCTest arithmetic baseline=$baseline_test_count mapped_renames=0 new=$new_test_count current=$current_test_count"
  elif [ "$public_clean_history" = true ]; then
    public_expected_test_count=1005
    public_head=$(git rev-parse HEAD)
    public_main=$(git rev-parse refs/heads/main 2>/dev/null || true)
    public_tag_type=$(git cat-file -t "refs/tags/$current_release_tag" 2>/dev/null || true)
    public_tag_commit=$(git rev-parse "refs/tags/$current_release_tag^{commit}" 2>/dev/null || true)
    public_commit_count=$(git rev-list --count --all 2>/dev/null || true)
    public_remote_count=$(git remote | sed '/^$/d' | wc -l | tr -d ' ')
    public_refs=$(
      git for-each-ref --format='%(refname)' refs/heads refs/tags |
        LC_ALL=C sort
    )
    public_expected_refs=$(printf 'refs/heads/main\nrefs/tags/%s\n' "$current_release_tag")
    current_test_count=$(printf '%s\n' "$current_test_identifiers" | sed '/^$/d' | wc -l | tr -d ' ')

    [ "$public_main" = "$public_head" ] || fail "public main does not equal HEAD"
    [ "$public_tag_type" = tag ] || fail "public $current_release_tag ref is not an annotated tag"
    [ "$public_tag_commit" = "$public_head" ] || fail "public $current_release_tag does not peel to HEAD"
    [ "$public_commit_count" = 1 ] || fail "public history must contain exactly one commit"
    if [ -z "$expected_public_origin" ]; then
      [ "$public_remote_count" = 0 ] || fail "public clean-history verification refuses configured remotes without --expected-origin"
    else
      public_remotes=$(git remote | LC_ALL=C sort)
      public_origin_urls=$(git config --local --get-all remote.origin.url || true)
      public_origin_pushurls=$(git config --local --get-all remote.origin.pushurl || true)
      public_effective_fetch_urls=$(git remote get-url --all origin 2>/dev/null || true)
      public_effective_push_urls=$(git remote get-url --push --all origin 2>/dev/null || true)
      [ "$public_remote_count" = 1 ] && [ "$public_remotes" = origin ] ||
        fail "public clean-history verification requires exactly one remote named origin"
      [ "$public_origin_urls" = "$expected_public_origin" ] ||
        fail "public origin fetch configuration differs from --expected-origin"
      [ -z "$public_origin_pushurls" ] || [ "$public_origin_pushurls" = "$expected_public_origin" ] ||
        fail "public origin push configuration differs from --expected-origin"
      [ "$public_effective_fetch_urls" = "$expected_public_origin" ] ||
        fail "public effective fetch URL differs from --expected-origin"
      [ "$public_effective_push_urls" = "$expected_public_origin" ] ||
        fail "public effective push URL differs from --expected-origin"
    fi
    [ "$public_refs" = "$public_expected_refs" ] || fail "public refs must be exactly main and $current_release_tag"
    [ "$current_test_count" = "$public_expected_test_count" ] ||
      fail "public XCTest inventory is $current_test_count; expected $public_expected_test_count"
    echo "verify-release: public clean-history XCTest inventory current=$current_test_count canonical-baseline-comparison=required"
  else
    fail "annotated RC1 baseline tag is unavailable for XCTest preservation"
  fi
fi

if ! grep -Eq 'MARKETING_VERSION = 1\.0\.0' macos/LokiBrief/LokiBrief.xcodeproj/project.pbxproj; then
  fail "native marketing version 1.0.0 is missing"
fi
if ! grep -Eq "CURRENT_PROJECT_VERSION = ${current_candidate_number}" macos/LokiBrief/LokiBrief.xcodeproj/project.pbxproj; then
  fail "native build number $current_candidate_number is missing"
fi

release_entitlements=macos/LokiBrief/LokiBrief/LokiBrief.entitlements
if command -v plutil >/dev/null 2>&1; then
  application_identifier=$(
    plutil -extract 'com\.apple\.application-identifier' raw -o - "$release_entitlements" 2>/dev/null || true
  )
  developer_team_identifier=$(
    plutil -extract 'com\.apple\.developer\.team-identifier' raw -o - "$release_entitlements" 2>/dev/null || true
  )
elif command -v python3 >/dev/null 2>&1; then
  entitlement_values=$(
    python3 - "$release_entitlements" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as handle:
    entitlements = plistlib.load(handle)
print(entitlements.get("com.apple.application-identifier", ""))
print(entitlements.get("com.apple.developer.team-identifier", ""))
PY
  )
  application_identifier=$(printf '%s\n' "$entitlement_values" | sed -n '1p')
  developer_team_identifier=$(printf '%s\n' "$entitlement_values" | sed -n '2p')
else
  application_identifier=
  developer_team_identifier=
  fail "plutil or python3 is required to inspect release entitlements"
fi
[ "$application_identifier" = '$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)' ] ||
  fail "release entitlements must retain the owner-neutral application identifier placeholders"
[ "$developer_team_identifier" = '$(DevelopmentTeam)' ] ||
  fail "release entitlements must retain the owner-neutral development Team placeholder"

action_refs=$(grep -R -n -E '^[[:space:]]*uses:[[:space:]]*[^ ]+@' .github/workflows || true)
if [ -z "$action_refs" ]; then
  fail "CI contains no action references"
elif printf '%s\n' "$action_refs" | grep -Ev '@[0-9a-f]{40}[[:space:]]*$' >/dev/null; then
  fail "every GitHub Action must be pinned to a 40-character commit SHA"
fi

for release_script in scripts/*.sh; do
  release_interpreter=$(sed -n '1p' "$release_script")
  case "$release_interpreter" in
    '#!/bin/bash') bash -n "$release_script" || fail "bash syntax failed: $release_script" ;;
    '#!/bin/sh') sh -n "$release_script" || fail "sh syntax failed: $release_script" ;;
    *) fail "unsupported shell interpreter in $release_script: $release_interpreter" ;;
  esac
done

scripts/run-disposable-app-smoke.sh --preflight-only || release_failed=1

link_findings=$(
  find . \
    -path './.git' -prune -o \
    -path './node_modules' -prune -o \
    -type f -name '*.md' -print0 |
    xargs -0 perl -MFile::Basename=dirname -MFile::Spec -ne '
      while (/\[[^\]]+\]\(([^)]+)\)/g) {
        my $target = $1;
        $target =~ s/^<|>$//g;
        $target =~ s/[[:space:]]+["\x27].*$//;
        next if $target =~ m{^(?:https?://|mailto:|#)}i;
        $target =~ s/#.*$//;
        next if $target eq q{};
        my $resolved = File::Spec->rel2abs($target, dirname($ARGV));
        print "$ARGV:$.:missing-link-target:$target\n" unless -e $resolved;
      }
      close ARGV if eof;
    '
)
if [ -n "$link_findings" ]; then
  fail "broken relative Markdown links:\n$link_findings"
fi

scripts/check-secrets.sh || release_failed=1
if [ "$release_has_git" = true ]; then
  git diff --check || release_failed=1
fi

if [ "$release_has_git" = true ] && [ "$allow_dirty" = false ] && [ -n "$(git status --porcelain)" ]; then
  fail "candidate worktree is not clean (use --allow-dirty only during development)"
fi

if [ "$release_failed" -ne 0 ]; then
  exit 1
fi

if [ "$release_has_git" = true ]; then
  echo "verify-release: passed (Git worktree)"
else
  echo "verify-release: passed (exported source tree; Git cleanliness unavailable)"
fi
