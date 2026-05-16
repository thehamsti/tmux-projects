#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: tools/release.sh <version> [--dry-run]

Creates a simple changelog entry, commits it, and creates an annotated git tag.

Examples:
  tools/release.sh v0.1.0
  tools/release.sh 0.1.0 --dry-run
USAGE
}

die() {
  printf 'release: %s\n' "$1" >&2
  exit 1
}

version=""
dry_run="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      dry_run="true"
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      if [[ -n "$version" ]]; then
        die "version was already provided"
      fi
      version="$1"
      ;;
  esac
  shift
done

[[ -n "$version" ]] || {
  usage >&2
  exit 1
}

if [[ "$version" != v* ]]; then
  version="v${version}"
fi

[[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]] ||
  die "version must look like v1.2.3"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
  die "must be run inside a git repository"

project_root="$(git rev-parse --show-toplevel)"
cd "$project_root"

if [[ -n "$(git status --porcelain)" ]]; then
  die "working tree must be clean before releasing"
fi

if git rev-parse -q --verify "refs/tags/${version}" >/dev/null; then
  die "tag already exists: ${version}"
fi

previous_tag="$(git describe --tags --abbrev=0 2>/dev/null || true)"
release_date="$(date +%Y-%m-%d)"

if [[ -n "$previous_tag" ]]; then
  commit_range="${previous_tag}..HEAD"
  compare_line="Changes since ${previous_tag}."
else
  commit_range="HEAD"
  compare_line="Initial release."
fi

changes="$(git log --format='- %s (%h)' "$commit_range")"
if [[ -z "$changes" ]]; then
  changes="- No changes recorded."
fi

entry="$(
  printf '## %s - %s\n\n' "$version" "$release_date"
  printf '%s\n\n' "$compare_line"
  printf '%s\n' "$changes"
)"

if [[ "$dry_run" == "true" ]]; then
  printf '%s\n' "$entry"
  exit 0
fi

changelog_file="CHANGELOG.md"
temp_changelog="$(mktemp "${TMPDIR:-/tmp}/tmux-projects-changelog.XXXXXX")"
trap 'rm -f "${temp_changelog:-}"' EXIT

if [[ -f "$changelog_file" ]]; then
  first_line="$(sed -n '1p' "$changelog_file")"
  if [[ "$first_line" == "# Changelog" ]]; then
    {
      printf '# Changelog\n\n'
      printf '%s\n\n' "$entry"
      sed '1d' "$changelog_file" | sed '/./,$!d'
    } >"$temp_changelog"
  else
    {
      printf '# Changelog\n\n'
      printf '%s\n\n' "$entry"
      cat "$changelog_file"
    } >"$temp_changelog"
  fi
else
  {
    printf '# Changelog\n\n'
    printf '%s\n' "$entry"
  } >"$temp_changelog"
fi

mv "$temp_changelog" "$changelog_file"
trap - EXIT

git add "$changelog_file"
git commit -m "Improvement: Release ${version}"
git tag -a "$version" -m "$entry"

printf 'Created release %s\n' "$version"
printf 'Review the changelog, then push with:\n'
printf '  git push origin HEAD %s\n' "$version"
