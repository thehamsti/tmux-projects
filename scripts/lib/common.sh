#!/usr/bin/env bash
set -uo pipefail

get_tmux_option() {
  local option_name="$1"
  local default_value="$2"
  local option_value=""

  if command -v tmux >/dev/null 2>&1 && [[ -n "${TMUX-}" ]]; then
    option_value="$(tmux show-option -gv "$option_name" 2>/dev/null || true)"
  fi

  if [[ -n "$option_value" ]]; then
    printf '%s\n' "$option_value"
    return 0
  fi

  printf '%s\n' "$default_value"
}

get_config_value() {
  local env_name="$1"
  local option_name="$2"
  local default_value="$3"
  local env_value="${!env_name-}"

  if [[ -n "$env_value" ]]; then
    printf '%s\n' "$env_value"
    return 0
  fi

  get_tmux_option "$option_name" "$default_value"
}

expand_path() {
  local raw_path="${1:-}"

  if [[ "$raw_path" == "~"* ]]; then
    printf '%s\n' "${HOME}${raw_path#\~}"
    return 0
  fi

  printf '%s\n' "$raw_path"
}

canonicalize_path() {
  local raw_path
  local expanded_path
  local parent_dir
  local base_name

  raw_path="${1:-}"
  expanded_path="$(expand_path "$raw_path")"

  if [[ -d "$expanded_path" ]]; then
    (
      cd "$expanded_path" >/dev/null 2>&1 &&
        pwd
    )
    return 0
  fi

  parent_dir="$(dirname "$expanded_path")"
  base_name="$(basename "$expanded_path")"

  if [[ -d "$parent_dir" ]]; then
    printf '%s/%s\n' "$(
      cd "$parent_dir" >/dev/null 2>&1 &&
        pwd
    )" "$base_name"
    return 0
  fi

  printf '%s\n' "$expanded_path"
}

registry_file() {
  expand_path "$(get_config_value "TMUX_PROJECTS_REGISTRY_FILE" "@tmux-projects-registry-file" "$HOME/.config/tmux-projects/projects.tsv")"
}

projects_dir() {
  expand_path "$(get_config_value "TMUX_PROJECTS_PROJECTS_DIR" "@tmux-projects-projects-dir" "$HOME/projects")"
}

default_template() {
  get_config_value "TMUX_PROJECTS_TEMPLATE" "@tmux-projects-template" "default"
}

fzf_height() {
  get_config_value "TMUX_PROJECTS_FZF_HEIGHT" "@tmux-projects-fzf-height" "40%"
}

use_popup() {
  get_config_value "TMUX_PROJECTS_USE_POPUP" "@tmux-projects-use-popup" "on"
}

scan_paths() {
  if [[ -n "${TMUX_PROJECTS_SCAN_PATHS-}" ]]; then
    printf '%s\n' "$TMUX_PROJECTS_SCAN_PATHS"
    return 0
  fi

  local configured_scan_paths
  configured_scan_paths="$(get_tmux_option "@tmux-projects-scan-paths" "")"

  if [[ -n "$configured_scan_paths" ]]; then
    printf '%s\n' "$configured_scan_paths"
    return 0
  fi

  configured_scan_paths="$(get_tmux_option "@project-paths" "")"
  if [[ -n "$configured_scan_paths" ]]; then
    printf '%s\n' "$configured_scan_paths"
    return 0
  fi

  printf '%s\n' "$HOME/projects $HOME/k16"
}

search_max_depth() {
  get_config_value "TMUX_PROJECTS_SEARCH_MAX_DEPTH" "@tmux-projects-search-max-depth" "4"
}

search_cache_dir() {
  local default_cache_dir

  default_cache_dir="$(dirname "$(registry_file)")/cache"
  expand_path "$(get_config_value "TMUX_PROJECTS_SEARCH_CACHE_DIR" "@tmux-projects-search-cache-dir" "$default_cache_dir")"
}

search_cache_ttl_seconds() {
  get_config_value "TMUX_PROJECTS_SEARCH_CACHE_TTL_SECONDS" "@tmux-projects-search-cache-ttl-seconds" "300"
}

scan_root_paths() {
  local configured_scan_paths="${1:-}"
  local root_path
  local expanded_root

  if [[ -z "$configured_scan_paths" ]]; then
    configured_scan_paths="$(scan_paths)"
  fi

  for root_path in $configured_scan_paths; do
    expanded_root="$(expand_path "$root_path")"
    [[ -d "$expanded_root" ]] || continue
    canonicalize_path "$expanded_root"
  done | sort -u
}

is_noise_directory_name() {
  local directory_name="${1:-}"

  case "$directory_name" in
    .git | .hg | .svn | .idea | .vscode | .next | .nuxt | .turbo | .cache | .sst | .venv | __pycache__ | node_modules | dist | build | coverage | vendor | target | out | tmp | temp | venv)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

emit_scanned_project_path() {
  local candidate_path
  local candidate_name

  candidate_path="$(canonicalize_path "${1:-}")"
  [[ -d "$candidate_path" ]] || return 0

  candidate_name="$(basename "$candidate_path")"
  if is_noise_directory_name "$candidate_name"; then
    return 0
  fi

  printf '%s\n' "$candidate_path"
}

string_matches_query() {
  local candidate_value="${1:-}"
  local query_value="${2:-}"
  local candidate_lower
  local query_token
  local token_lower

  [[ -z "$query_value" ]] && return 0

  candidate_lower="$(printf '%s' "$candidate_value" | tr '[:upper:]' '[:lower:]')"

  for query_token in $query_value; do
    token_lower="$(printf '%s' "$query_token" | tr '[:upper:]' '[:lower:]')"
    [[ "$candidate_lower" == *"$token_lower"* ]] || return 1
  done

  return 0
}

lowercase_value() {
  printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'
}

scan_paths_fingerprint() {
  local fingerprint_source

  fingerprint_source="$(scan_paths)"
  fingerprint_source="${fingerprint_source}"$'\n'"$(search_max_depth)"
  printf '%s' "$fingerprint_source" | cksum | awk '{print $1}'
}

search_cache_file() {
  printf '%s/projects-%s.tsv\n' "$(search_cache_dir)" "$(scan_paths_fingerprint)"
}

search_cache_lock_dir() {
  printf '%s.lock\n' "$(search_cache_file)"
}

file_mtime_epoch() {
  local target_file="${1:-}"

  stat -f '%m' "$target_file" 2>/dev/null || stat -c '%Y' "$target_file" 2>/dev/null
}

search_cache_is_fresh() {
  local cache_file="$1"
  local ttl_seconds
  local modified_at
  local now_epoch

  [[ -f "$cache_file" ]] || return 1

  ttl_seconds="$(search_cache_ttl_seconds)"
  modified_at="$(file_mtime_epoch "$cache_file" 2>/dev/null || true)"
  [[ -n "$modified_at" ]] || return 1

  now_epoch="$(date +%s)"
  [[ $((now_epoch - modified_at)) -le $ttl_seconds ]]
}

find_searchable_directories() {
  local root_path="$1"
  local max_depth="$2"

  find "$root_path" \
    \( -type d \( \
    -name .git -o \
    -name .hg -o \
    -name .svn -o \
    -name .idea -o \
    -name .vscode -o \
    -name .next -o \
    -name .nuxt -o \
    -name .turbo -o \
    -name .cache -o \
    -name .sst -o \
    -name .venv -o \
    -name __pycache__ -o \
    -name node_modules -o \
    -name dist -o \
    -name build -o \
    -name coverage -o \
    -name vendor -o \
    -name target -o \
    -name out -o \
    -name tmp -o \
    -name temp -o \
    -name venv \
    \) -prune \) -o \
    -mindepth 1 -maxdepth "$max_depth" -type d -print 2>/dev/null
}

build_search_cache_file() {
  local cache_file
  local cache_dir
  local temp_file
  local root_path
  local candidate_path
  local relative_path
  local is_top_level
  local candidate_name

  cache_file="$(search_cache_file)"
  cache_dir="$(dirname "$cache_file")"
  mkdir -p "$cache_dir"
  temp_file="$(mktemp "${cache_dir}/projects.XXXXXX")"

  while IFS= read -r root_path; do
    while IFS= read -r candidate_path; do
      candidate_path="$(emit_scanned_project_path "$candidate_path")"
      [[ -n "$candidate_path" ]] || continue

      relative_path="${candidate_path#"$root_path"/}"
      is_top_level="0"
      if [[ "$relative_path" == "$candidate_path" || "$relative_path" != */* ]]; then
        is_top_level="1"
      fi

      candidate_name="$(basename "$candidate_path")"
      printf '%s\t%s\t%s\t%s\n' \
        "$(lowercase_value "$candidate_name")" \
        "$candidate_name" \
        "$candidate_path" \
        "$is_top_level"
    done < <(find_searchable_directories "$root_path" "$(search_max_depth)" | sort)
  done < <(scan_root_paths) |
    awk -F '\t' '!seen[$3]++ { print $0 }' >"$temp_file"

  mv "$temp_file" "$cache_file"
}

ensure_search_cache() {
  local cache_file
  local lock_dir

  cache_file="$(search_cache_file)"
  if search_cache_is_fresh "$cache_file"; then
    printf '%s\n' "$cache_file"
    return 0
  fi

  if [[ ! -f "$cache_file" ]]; then
    build_search_cache_file
    printf '%s\n' "$cache_file"
    return 0
  fi

  lock_dir="$(search_cache_lock_dir)"
  if mkdir "$lock_dir" 2>/dev/null; then
    (
      build_search_cache_file
      rmdir "$lock_dir" >/dev/null 2>&1 || true
    ) >/dev/null 2>&1 &
  fi

  printf '%s\n' "$cache_file"
}

list_matching_project_paths() {
  local query_value="${1:-}"
  local root_path
  local candidate_path
  local cache_file
  local normalized_query

  if [[ -z "$query_value" ]]; then
    while IFS= read -r root_path; do
      while IFS= read -r candidate_path; do
        candidate_path="$(emit_scanned_project_path "$candidate_path")"
        [[ -n "$candidate_path" ]] || continue
        printf '%s\n' "$candidate_path"
      done < <(find_searchable_directories "$root_path" 1 | sort)
    done < <(scan_root_paths)
    return 0
  fi

  cache_file="$(ensure_search_cache)"
  normalized_query="$(lowercase_value "$query_value")"

  awk -F '\t' -v query="$normalized_query" '
    BEGIN {
      token_count = split(query, tokens, /[[:space:]]+/)
    }
    {
      matched = 1
      for (i = 1; i <= token_count; i++) {
        if (tokens[i] == "") {
          continue
        }
        if (index($1, tokens[i]) == 0) {
          matched = 0
          break
        }
      }
      if (matched) {
        print $3
      }
    }
  ' "$cache_file"
}

list_scanned_project_paths() {
  local root_path
  local candidate_path
  local relative_path

  while IFS= read -r root_path; do
    while IFS= read -r candidate_path; do
      candidate_path="$(emit_scanned_project_path "$candidate_path")"
      [[ -n "$candidate_path" ]] || continue

      relative_path="${candidate_path#"$root_path"/}"
      if [[ "$relative_path" == "$candidate_path" || "$relative_path" != */* ]]; then
        printf '%s\n' "$candidate_path"
        continue
      fi

      if [[ -d "${candidate_path}/.git" ]]; then
        printf '%s\n' "$candidate_path"
      fi
    done < <(find_searchable_directories "$root_path" "$(search_max_depth)" | sort)
  done < <(scan_root_paths) | sort -u
}

path_is_under_scan_roots() {
  local candidate_path
  local root_path

  candidate_path="$(canonicalize_path "${1:-}")"

  while IFS= read -r root_path; do
    case "$candidate_path" in
      "$root_path" | "$root_path"/*)
        return 0
        ;;
    esac
  done < <(scan_root_paths)

  return 1
}

lookup_scanned_project_path() {
  local lookup_name="$1"
  local matched_path=""
  local match_count=0
  local candidate_path

  while IFS= read -r candidate_path; do
    if [[ "$(basename "$candidate_path")" != "$lookup_name" ]]; then
      continue
    fi

    matched_path="$candidate_path"
    match_count=$((match_count + 1))
  done < <(list_matching_project_paths "$lookup_name")

  if [[ $match_count -eq 1 ]]; then
    printf '%s\n' "$matched_path"
    return 0
  fi

  if [[ $match_count -gt 1 ]]; then
    display_error "Multiple scanned projects matched: $lookup_name"
    return 1
  fi

  return 1
}

supports_popup() {
  [[ "$(use_popup)" == "on" ]] || return 1
  command -v tmux >/dev/null 2>&1 || return 1
  tmux list-commands 2>/dev/null | grep -q '^display-popup'
}

sanitize_field() {
  printf '%s' "${1:-}" | tr '\t\r\n' '   '
}

ensure_registry_file() {
  local path
  local parent_dir

  path="$(registry_file)"
  parent_dir="$(dirname "$path")"
  mkdir -p "$parent_dir"

  if [[ ! -f "$path" ]]; then
    {
      printf '# name\trepo_url\tlocal_path\ttemplate\tnotes\n'
      printf '# managed by tmux-projects\n'
    } >"$path"
  fi
}

PARSED_REGISTRY_NAME=""
PARSED_REGISTRY_URL=""
PARSED_REGISTRY_PATH=""
PARSED_REGISTRY_TEMPLATE=""
PARSED_REGISTRY_NOTES=""

# shellcheck disable=SC2034
parse_registry_line() {
  local line="$1"
  local remainder="$line"

  PARSED_REGISTRY_NAME="${remainder%%$'\t'*}"
  remainder="${remainder#*$'\t'}"

  if [[ "$line" != *$'\t'* ]]; then
    PARSED_REGISTRY_URL=""
    PARSED_REGISTRY_PATH=""
    PARSED_REGISTRY_TEMPLATE=""
    PARSED_REGISTRY_NOTES=""
    return 0
  fi

  PARSED_REGISTRY_URL="${remainder%%$'\t'*}"
  remainder="${remainder#*$'\t'}"
  PARSED_REGISTRY_PATH="${remainder%%$'\t'*}"
  remainder="${remainder#*$'\t'}"
  PARSED_REGISTRY_TEMPLATE="${remainder%%$'\t'*}"

  if [[ "$remainder" == *$'\t'* ]]; then
    PARSED_REGISTRY_NOTES="${remainder#*$'\t'}"
  else
    PARSED_REGISTRY_NOTES=""
  fi
}

list_registry_entries() {
  local path
  local line

  path="$(registry_file)"
  ensure_registry_file

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    [[ "$line" == \#* ]] && continue
    printf '%s\n' "$line"
  done <"$path"
}

lookup_registry_entry() {
  local lookup_name="$1"
  local line

  ensure_registry_file

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    [[ "$line" == \#* ]] && continue
    parse_registry_line "$line"
    if [[ "$PARSED_REGISTRY_NAME" == "$lookup_name" ]]; then
      printf '%s\n' "$line"
      return 0
    fi
  done <"$(registry_file)"

  return 1
}

upsert_registry_entry() {
  local name="$1"
  local url="$2"
  local path="$3"
  local template="$4"
  local notes="$5"
  local registry_path
  local temp_file
  local line

  ensure_registry_file
  registry_path="$(registry_file)"
  temp_file="$(mktemp "${TMPDIR:-/tmp}/tmux-projects.registry.XXXXXX")"

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -z "$line" || "$line" == \#* ]]; then
      printf '%s\n' "$line" >>"$temp_file"
      continue
    fi

    parse_registry_line "$line"
    if [[ "$PARSED_REGISTRY_PATH" == "$path" ]]; then
      continue
    fi
    if [[ -n "$url" && "$PARSED_REGISTRY_URL" == "$url" ]]; then
      continue
    fi

    printf '%s\n' "$line" >>"$temp_file"
  done <"$registry_path"

  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$(sanitize_field "$name")" \
    "$(sanitize_field "$url")" \
    "$(sanitize_field "$path")" \
    "$(sanitize_field "$template")" \
    "$(sanitize_field "$notes")" >>"$temp_file"

  mv "$temp_file" "$registry_path"
}

is_repo_url() {
  local input_value="${1:-}"

  case "$input_value" in
    http://* | https://* | ssh://* | git@*:* | *.git)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

infer_name_from_repo_url() {
  local clean_value="${1%/}"
  clean_value="${clean_value%.git}"
  printf '%s\n' "${clean_value##*/}"
}

normalize_session_name() {
  local raw_name="${1:-}"
  local session_name

  session_name="$(printf '%s' "$raw_name" | sed -E 's/[^[:alnum:]._-]+/_/g; s/^_+//; s/_+$//')"
  if [[ -z "$session_name" ]]; then
    printf 'project\n'
    return 0
  fi

  printf '%s\n' "$session_name"
}

tmux_session_exists() {
  local session_name="$1"
  command -v tmux >/dev/null 2>&1 || return 1
  tmux has-session -t "$session_name" 2>/dev/null
}

display_info() {
  local message="$1"

  if command -v tmux >/dev/null 2>&1 && [[ -n "${TMUX-}" ]]; then
    tmux display-message "$message"
    return 0
  fi

  printf '%s\n' "$message"
}

display_error() {
  local message="$1"
  display_info "$message" >&2
}

create_workspace() {
  local session_name="$1"
  local working_dir="$2"
  local template_name="$3"
  local main_pane_id=""
  local right_pane_id=""

  case "$template_name" in
    default)
      tmux new-session -d -s "$session_name" -c "$working_dir"
      main_pane_id="$(tmux display-message -p -t "$session_name" '#{pane_id}')"
      tmux rename-window -t "$session_name" main
      right_pane_id="$(tmux split-window -h -P -F '#{pane_id}' -t "$session_name":main -c "$working_dir")"
      tmux split-window -v -t "$right_pane_id" -c "$working_dir"
      tmux select-layout -t "$session_name":main main-vertical
      tmux select-pane -t "$main_pane_id"
      tmux new-window -t "$session_name" -n bg -c "$working_dir"
      tmux new-window -t "$session_name" -n logs -c "$working_dir"
      tmux select-window -t "$session_name":main
      ;;
    *)
      display_error "Unknown template: $template_name"
      return 1
      ;;
  esac
}

switch_to_session() {
  local session_name="$1"
  tmux switch-client -t "$session_name"
}
