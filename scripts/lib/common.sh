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
