#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

search_query=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --query)
      search_query="${2-}"
      shift 2
      ;;
    *)
      display_error "Unknown argument: $1"
      exit 1
      ;;
  esac
done

build_candidates() {
  local query_value="$1"
  local candidate_path
  local candidate_name
  local line
  local session_name
  local seen_sessions=""

  while IFS= read -r candidate_path; do
    [[ -z "$candidate_path" ]] && continue
    candidate_name="$(basename "$candidate_path")"
    printf 'project\t%s\t%s\t-\n' "$candidate_name" "$candidate_path"
    seen_sessions+="$(normalize_session_name "$candidate_name")"$'\n'
  done < <(list_matching_project_paths "$query_value" | sort -u)

  while IFS= read -r line || [[ -n "$line" ]]; do
    parse_registry_line "$line"
    [[ -n "$PARSED_REGISTRY_PATH" ]] || continue

    if path_is_under_scan_roots "$PARSED_REGISTRY_PATH"; then
      continue
    fi

    if ! string_matches_query "$PARSED_REGISTRY_NAME" "$query_value"; then
      continue
    fi

    printf 'project\t%s\t%s\t%s\n' "$PARSED_REGISTRY_NAME" "$PARSED_REGISTRY_PATH" "$PARSED_REGISTRY_URL"
    seen_sessions+="$(normalize_session_name "$PARSED_REGISTRY_NAME")"$'\n'
  done < <(list_registry_entries)

  if ! command -v tmux >/dev/null 2>&1; then
    return 0
  fi

  while IFS= read -r session_name || [[ -n "$session_name" ]]; do
    [[ -z "$session_name" ]] && continue

    if ! string_matches_query "$session_name" "$query_value"; then
      continue
    fi

    if printf '%s' "$seen_sessions" | grep -qxF "$session_name"; then
      continue
    fi

    printf 'session\t%s\t-\t-\n' "$session_name"
  done < <(tmux list-sessions -F '#S' 2>/dev/null || true)
}

build_candidates "$search_query"
