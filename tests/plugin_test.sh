#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

assert_eq() {
  local actual="$1"
  local expected="$2"
  local message="$3"

  if [[ "$actual" != "$expected" ]]; then
    printf 'assertion failed: %s\nexpected: %s\nactual:   %s\n' "$message" "$expected" "$actual" >&2
    exit 1
  fi
}

test_common_helpers() {
  local https_name
  local ssh_name
  local normalized_name

  source "${PROJECT_ROOT}/scripts/lib/common.sh"

  https_name="$(infer_name_from_repo_url "https://github.com/acme/demo-app.git")"
  ssh_name="$(infer_name_from_repo_url "git@github.com:acme/demo-app.git")"
  normalized_name="$(normalize_session_name "feature/my cool:project")"

  assert_eq "$https_name" "demo-app" "infer_name_from_repo_url should strip .git over https"
  assert_eq "$ssh_name" "demo-app" "infer_name_from_repo_url should strip .git over ssh"
  assert_eq "$normalized_name" "feature_my_cool_project" "normalize_session_name should make tmux-safe names"
}

test_registry_deduplicates_local_projects() {
  local temp_root
  local registry_file
  local project_dir
  local entry_count

  temp_root="$(mktemp -d "${TMPDIR:-/tmp}/tmux-projects-test.XXXXXX")"
  trap 'rm -rf "${temp_root:-}"' RETURN

  registry_file="${temp_root}/projects.tsv"
  project_dir="${temp_root}/demo"
  mkdir -p "$project_dir"

  TMUX_PROJECTS_REGISTRY_FILE="$registry_file" \
    bash "${PROJECT_ROOT}/scripts/add-project.sh" --input "$project_dir" --no-open >/dev/null
  TMUX_PROJECTS_REGISTRY_FILE="$registry_file" \
    bash "${PROJECT_ROOT}/scripts/add-project.sh" --input "$project_dir" --notes "second pass" --no-open >/dev/null

  entry_count="$(grep -vc '^#' "$registry_file" | tr -d ' ')"
  assert_eq "$entry_count" "1" "local project registration should upsert instead of duplicate"
}

main() {
  test_common_helpers
  test_registry_deduplicates_local_projects
  printf 'plugin tests passed\n'
}

main "$@"
