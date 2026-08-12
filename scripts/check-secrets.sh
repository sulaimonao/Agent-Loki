#!/bin/sh
set -eu

usage() {
  echo "usage: scripts/check-secrets.sh [--history]"
}

scan_history=false
case "${1-}" in
  "") ;;
  -h|--help) usage; exit 0 ;;
  --history) scan_history=true ;;
  *) usage >&2; exit 2 ;;
esac

release_script_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P) || exit 2
release_root=$(dirname "$release_script_dir")
release_has_git=false
if release_git_root=$(git -C "$release_root" rev-parse --show-toplevel 2>/dev/null); then
  release_root=$release_git_root
  release_has_git=true
fi
cd "$release_root"

scan_worktree() {
  find . \
    -path './.git' -prune -o \
    -path './node_modules' -prune -o \
    -path './dist' -prune -o \
    -path './DerivedData' -prune -o \
    -type f -print0 |
    xargs -0 perl -ne '
      if (-B $ARGV) { close ARGV if eof; next; }
      my @classes;
      push @classes, "private-key-header"
        if /-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----/;
      push @classes, "slack-token-shape"
        if /xox[baprs]-[A-Za-z0-9-]{10,}/;
      push @classes, "github-token-shape"
        if /(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})/;
      push @classes, "cloud-token-shape"
        if /(?:AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}|sk_live_[0-9A-Za-z]{16,}|glpat-[0-9A-Za-z_-]{16,}|npm_[0-9A-Za-z]{20,})/;
      push @classes, "discord-token-or-webhook-shape"
        if /(?:[A-Za-z0-9_-]{23,28}\.[A-Za-z0-9_-]{6}\.[A-Za-z0-9_-]{25,40}|discord(?:app)?\.com\/api\/webhooks\/[0-9]{8,}\/[A-Za-z0-9_-]{20,})/;
      for my $class (@classes) {
        print "$ARGV:$.:$class\n";
      }
      close ARGV if eof;
    '
}

worktree_findings=$(scan_worktree)
if [ -n "$worktree_findings" ]; then
  echo "check-secrets: potential secret classifications found:" >&2
  printf '%s\n' "$worktree_findings" >&2
  echo "check-secrets: matched values were intentionally not printed" >&2
  exit 1
fi

if [ "$scan_history" = true ]; then
  if [ "$release_has_git" = false ]; then
    echo "check-secrets: --history requires a Git repository" >&2
    exit 2
  fi
  history_findings=$(
    git rev-list --objects --all |
      while IFS=' ' read -r release_oid release_path; do
        release_object_type=$(git cat-file -t "$release_oid" 2>/dev/null) || continue
        [ "$release_object_type" = blob ] ||
          [ "$release_object_type" = commit ] ||
          [ "$release_object_type" = tag ] || continue
        git cat-file "$release_object_type" "$release_oid" |
          perl -0777 -ne '
            my @classes;
            push @classes, "private-key-header"
              if /-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----/;
            push @classes, "slack-token-shape"
              if /xox[baprs]-[A-Za-z0-9-]{10,}/;
            push @classes, "github-token-shape"
              if /(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})/;
            push @classes, "cloud-token-shape"
              if /(?:AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}|sk_live_[0-9A-Za-z]{16,}|glpat-[0-9A-Za-z_-]{16,}|npm_[0-9A-Za-z]{20,})/;
            push @classes, "discord-token-or-webhook-shape"
              if /(?:[A-Za-z0-9_-]{23,28}\.[A-Za-z0-9_-]{6}\.[A-Za-z0-9_-]{25,40}|discord(?:app)?\.com\/api\/webhooks\/[0-9]{8,}\/[A-Za-z0-9_-]{20,})/;
            print "$_\n" for @classes;
          ' |
          while IFS= read -r release_class; do
            printf '%s:%s:%s\n' "$release_oid" "${release_path:-<$release_object_type-object>}" "$release_class"
          done
      done
  )
  history_path_findings=$(
    git rev-list --all |
      while IFS= read -r release_commit; do
        git diff-tree --root --no-commit-id --no-renames --name-only -r -z "$release_commit"
      done |
      perl -0ne '
        chomp;
        next if $_ eq "";
        my @classes;
        push @classes, "private-user-path"
          if m{/(?:Users|home)/[^/\s`"<>]+(?:/|$)};
        push @classes, "private-windows-user-path"
          if m{[A-Za-z]:[\\/]Users[\\/][^\\/\s`"<>]+(?:[\\/]|$)}i;
        push @classes, "slack-token-shape"
          if /xox[baprs]-[A-Za-z0-9-]{10,}/;
        push @classes, "github-token-shape"
          if /(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})/;
        push @classes, "cloud-token-shape"
          if /(?:AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}|sk_live_[0-9A-Za-z]{16,}|glpat-[0-9A-Za-z_-]{16,}|npm_[0-9A-Za-z]{20,})/;
        push @classes, "discord-token-or-webhook-shape"
          if /(?:[A-Za-z0-9_-]{23,28}\.[A-Za-z0-9_-]{6}\.[A-Za-z0-9_-]{25,40}|discord(?:app)?\.com\/api\/webhooks\/[0-9]{8,}\/[A-Za-z0-9_-]{20,})/;
        print "reachable-tree-path:$class\n" for @classes;
      '
  )
  if [ -n "$history_path_findings" ]; then
    history_findings="${history_findings}${history_findings:+
}${history_path_findings}"
  fi
  if [ -n "$history_findings" ]; then
    echo "check-secrets: potential secret classifications found in reachable history:" >&2
    printf '%s\n' "$history_findings" >&2
    echo "check-secrets: matched values were intentionally not printed" >&2
    exit 1
  fi
fi

if [ "$scan_history" = true ]; then
  echo "check-secrets: passed (worktree and reachable history)"
else
  echo "check-secrets: passed (worktree)"
fi
