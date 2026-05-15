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
  local line
  local session_name

  while IFS= read -r line || [[ -n "$line" ]]; do
    parse_registry_line "$line"
    session_name="$(normalize_session_name "$PARSED_REGISTRY_NAME")"

    if ! tmux_session_exists "$session_name"; then
      continue
    fi

    if ! string_matches_query "$PARSED_REGISTRY_NAME" "$query_value" &&
      ! string_matches_query "$session_name" "$query_value"; then
      continue
    fi

    printf 'session\t%s\t%s\t%s\n' "$session_name" "$PARSED_REGISTRY_PATH" "$PARSED_REGISTRY_URL"
  done < <(list_registry_entries)
}

build_candidates "$search_query"
