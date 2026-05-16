#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: tools/release.sh <version|major|minor|patch> [--dry-run]

Creates a changelog entry, commits it, tags it, pushes it, and creates a GitHub release.

Examples:
  tools/release.sh patch
  tools/release.sh minor --dry-run
  tools/release.sh v0.1.0
  tools/release.sh 0.1.0
USAGE
}

die() {
  printf 'release: %s\n' "$1" >&2
  exit 1
}

release_input=""
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
      if [[ -n "$release_input" ]]; then
        die "version was already provided"
      fi
      release_input="$1"
      ;;
  esac
  shift
done

[[ -n "$release_input" ]] || {
  usage >&2
  exit 1
}

git rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
  die "must be run inside a git repository"

project_root="$(git rev-parse --show-toplevel)"
cd "$project_root"

if [[ -n "$(git status --porcelain)" ]]; then
  die "working tree must be clean before releasing"
fi

latest_release_tag() {
  git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname |
    awk '/^v[0-9]+\.[0-9]+\.[0-9]+$/ { print; exit }'
}

bump_version() {
  local bump_type="$1"
  local base_tag="$2"
  local major
  local minor
  local patch

  [[ "$base_tag" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] ||
    die "latest tag must look like v1.2.3 to use ${bump_type}"

  major="${BASH_REMATCH[1]}"
  minor="${BASH_REMATCH[2]}"
  patch="${BASH_REMATCH[3]}"

  case "$bump_type" in
    major)
      major=$((major + 1))
      minor=0
      patch=0
      ;;
    minor)
      minor=$((minor + 1))
      patch=0
      ;;
    patch)
      patch=$((patch + 1))
      ;;
    *)
      die "unknown bump type: ${bump_type}"
      ;;
  esac

  printf 'v%s.%s.%s\n' "$major" "$minor" "$patch"
}

previous_tag="$(latest_release_tag)"

case "$release_input" in
  major | minor | patch)
    [[ -n "$previous_tag" ]] ||
      die "cannot bump ${release_input}: no existing vX.Y.Z tag found"
    version="$(bump_version "$release_input" "$previous_tag")"
    ;;
  *)
    version="$release_input"
    if [[ "$version" != v* ]]; then
      version="v${version}"
    fi

    [[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]] ||
      die "version must look like v1.2.3 or be major, minor, or patch"
    ;;
esac

if git rev-parse -q --verify "refs/tags/${version}" >/dev/null; then
  die "tag already exists: ${version}"
fi

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

command -v gh >/dev/null 2>&1 ||
  die "GitHub CLI is required to create the GitHub release"

changelog_file="changelog.md"
temp_changelog="$(mktemp "${TMPDIR:-/tmp}/tmux-projects-changelog.XXXXXX")"
release_notes_file="$(mktemp "${TMPDIR:-/tmp}/tmux-projects-release-notes.XXXXXX")"
trap 'rm -f "${temp_changelog:-}" "${release_notes_file:-}"' EXIT

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
printf '%s\n' "$entry" >"$release_notes_file"

git add "$changelog_file"
git commit \
  -m "Improvement: Release ${version}" \
  -m "Co-authored-by: Codex <noreply@openai.com>"
git tag -a "$version" -m "$entry"
git push origin HEAD "$version"
gh release create "$version" \
  --title "$version" \
  --notes-file "$release_notes_file" \
  --verify-tag

rm -f "$release_notes_file"
trap - EXIT

printf 'Created release %s\n' "$version"
printf 'Updated %s and created the GitHub release.\n' "$changelog_file"
