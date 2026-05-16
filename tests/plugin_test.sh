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

test_release_script_creates_changelog_commit_and_tag() {
  local temp_root
  local changelog
  local tag_subject

  temp_root="$(mktemp -d "${TMPDIR:-/tmp}/tmux-projects-release-test.XXXXXX")"
  trap 'rm -rf "'"${temp_root:-}"'"' RETURN

  cp "${PROJECT_ROOT}/tools/release.sh" "${temp_root}/release.sh"

  (
    cd "$temp_root"
    git init -q
    git config user.name "tmux-projects test"
    git config user.email "tmux-projects@example.test"

    printf 'one\n' >plugin.txt
    git add release.sh plugin.txt
    git commit -q -m "Improvement: Add plugin"
    git tag -a v0.1.0 -m "v0.1.0"

    printf 'two\n' >>plugin.txt
    git add plugin.txt
    git commit -q -m "Bug: Fix plugin startup"

    bash ./release.sh v0.2.0 >/dev/null
  )

  changelog="$(cat "${temp_root}/CHANGELOG.md")"
  tag_subject="$(git -C "$temp_root" tag -l v0.2.0)"

  [[ "$changelog" == *"## v0.2.0 - "* ]] || {
    printf 'assertion failed: release script should write a versioned changelog entry\n' >&2
    exit 1
  }
  [[ "$changelog" == *"Changes since v0.1.0."* ]] || {
    printf 'assertion failed: release script should mention the previous tag\n' >&2
    exit 1
  }
  [[ "$changelog" == *"Bug: Fix plugin startup"* ]] || {
    printf 'assertion failed: release script should include commit subjects since the previous tag\n' >&2
    exit 1
  }
  assert_eq "$tag_subject" "v0.2.0" "release script should create the requested tag"

  rm -rf "$temp_root"
  trap - RETURN
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

test_create_workspace_uses_active_window_indexes() {
  local temp_root
  local socket_name
  local workspace_root
  local window_names
  local pane_count

  temp_root="$(mktemp -d "${TMPDIR:-/tmp}/tmux-projects-test.XXXXXX")"
  socket_name="tmux-projects-test-$$"
  workspace_root="${temp_root}/workspace"
  mkdir -p "$workspace_root"
  trap 'tmux -L "'"${socket_name}"'" kill-server >/dev/null 2>&1 || true; rm -rf "'"${temp_root:-}"'"' RETURN

  tmux -L "$socket_name" -f /dev/null new-session -d -s smoke -c "$workspace_root"

  bash -lc '
    tmux() {
      command tmux -L "'"$socket_name"'" "$@"
    }

    source "'"${PROJECT_ROOT}/scripts/lib/common.sh"'"
    create_workspace demo "'"$workspace_root"'" default
  '

  window_names="$(tmux -L "$socket_name" list-windows -t demo -F '#W' | paste -sd ',' -)"
  pane_count="$(tmux -L "$socket_name" list-panes -t demo:main | wc -l | tr -d ' ')"

  assert_eq "$window_names" "main,bg,logs" "default template should create the expected windows"
  assert_eq "$pane_count" "3" "default template should create a 3-pane main window under base-index 0"

  tmux -L "$socket_name" kill-server >/dev/null 2>&1 || true
  rm -rf "$temp_root"
  trap - RETURN
}

test_project_search_scans_roots_on_demand() {
  local temp_root
  local search_root
  local canonical_search_root
  local cache_dir
  local cache_file
  local empty_results
  local api_results
  local ui_results
  local import_results

  temp_root="$(mktemp -d "${TMPDIR:-/tmp}/tmux-projects-test.XXXXXX")"
  search_root="${temp_root}/root"
  canonical_search_root="$(cd "$temp_root" && pwd)/root"
  cache_dir="${temp_root}/cache"
  mkdir -p "${search_root}/alpha"
  mkdir -p "${search_root}/mono/packages/api/.git"
  mkdir -p "${search_root}/mono/packages/ui"
  mkdir -p "${search_root}/node_modules/ignored"
  mkdir -p "${search_root}/dist/generated"
  trap 'rm -rf "'"${temp_root:-}"'"' RETURN

  empty_results="$(
    TMUX_PROJECTS_SCAN_PATHS="$search_root" \
      bash -lc '
        source "'"${PROJECT_ROOT}/scripts/lib/common.sh"'"
        list_matching_project_paths "" | paste -sd "," -
      '
  )"
  api_results="$(
    TMUX_PROJECTS_SCAN_PATHS="$search_root" \
      TMUX_PROJECTS_SEARCH_CACHE_DIR="$cache_dir" \
      bash -lc '
        source "'"${PROJECT_ROOT}/scripts/lib/common.sh"'"
        list_matching_project_paths "api" | paste -sd "," -
      '
  )"
  ui_results="$(
    TMUX_PROJECTS_SCAN_PATHS="$search_root" \
      TMUX_PROJECTS_SEARCH_CACHE_DIR="$cache_dir" \
      bash -lc '
        source "'"${PROJECT_ROOT}/scripts/lib/common.sh"'"
        list_matching_project_paths "ui" | paste -sd "," -
      '
  )"
  import_results="$(
    TMUX_PROJECTS_SCAN_PATHS="$search_root" \
      bash -lc '
        source "'"${PROJECT_ROOT}/scripts/lib/common.sh"'"
        list_scanned_project_paths | paste -sd "," -
      '
  )"
  cache_file="$(
    TMUX_PROJECTS_SCAN_PATHS="$search_root" \
      TMUX_PROJECTS_SEARCH_CACHE_DIR="$cache_dir" \
      bash -lc '
        source "'"${PROJECT_ROOT}/scripts/lib/common.sh"'"
        search_cache_file
      '
  )"

  assert_eq "$empty_results" "${canonical_search_root}/alpha,${canonical_search_root}/mono" "empty search should stay at the root level"
  assert_eq "$api_results" "${canonical_search_root}/mono/packages/api" "typed search should find nested matching directories"
  assert_eq "$ui_results" "${canonical_search_root}/mono/packages/ui" "typed search should match nested folders that are not git roots"
  assert_eq "$import_results" "${canonical_search_root}/alpha,${canonical_search_root}/mono,${canonical_search_root}/mono/packages/api" "imports should stay bounded to top-level dirs plus nested git repos"
  [[ -f "$cache_file" ]] || {
    printf 'assertion failed: typed search should create a cache file\nmissing: %s\n' "$cache_file" >&2
    exit 1
  }

  rm -rf "$temp_root"
  trap - RETURN
}

test_open_project_search_only_lists_active_sessions() {
  local temp_root
  local registry_file
  local project_dir
  local canonical_project_dir
  local socket_name
  local search_results

  temp_root="$(mktemp -d "${TMPDIR:-/tmp}/tmux-projects-test.XXXXXX")"
  registry_file="${temp_root}/projects.tsv"
  project_dir="${temp_root}/demo"
  canonical_project_dir="$(cd "$temp_root" && pwd)/demo"
  socket_name="tmux-projects-open-test-$$"
  mkdir -p "$project_dir"
  trap 'tmux -L "'"${socket_name}"'" kill-server >/dev/null 2>&1 || true; rm -rf "'"${temp_root:-}"'"' RETURN

  TMUX_PROJECTS_REGISTRY_FILE="$registry_file" \
    bash "${PROJECT_ROOT}/scripts/add-project.sh" --input "$project_dir" --no-open >/dev/null

  tmux -L "$socket_name" -f /dev/null new-session -d -s demo -c "$project_dir"
  tmux -L "$socket_name" new-session -d -s scratch -c "$project_dir"

  search_results="$(
    TMUX_PROJECTS_REGISTRY_FILE="$registry_file" \
      bash -lc '
      tmux() {
        command tmux -L "'"$socket_name"'" "$@"
      }

      set -- --query demo
      source "'"${PROJECT_ROOT}/scripts/search-open-projects.sh"'"
    ' | paste -sd "," -
  )"

  assert_eq "$search_results" $'session\tdemo\t'"${canonical_project_dir}"$'\t' "open-project search should only list active registry-backed project sessions"

  tmux -L "$socket_name" kill-server >/dev/null 2>&1 || true
  rm -rf "$temp_root"
  trap - RETURN
}

main() {
  test_release_script_creates_changelog_commit_and_tag
  test_common_helpers
  test_registry_deduplicates_local_projects
  test_create_workspace_uses_active_window_indexes
  test_project_search_scans_roots_on_demand
  test_open_project_search_only_lists_active_sessions
  printf 'plugin tests passed\n'
}

main "$@"
