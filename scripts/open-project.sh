#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

project_name=""
project_path=""
project_template=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      project_name="${2-}"
      shift 2
      ;;
    --path)
      project_path="${2-}"
      shift 2
      ;;
    --template)
      project_template="${2-}"
      shift 2
      ;;
    *)
      display_error "Unknown argument: $1"
      exit 1
      ;;
  esac
done

if [[ -z "$project_path" && -n "$project_name" ]]; then
  if project_path="$(lookup_scanned_project_path "$project_name" 2>/dev/null)"; then
    :
  elif entry_line="$(lookup_registry_entry "$project_name" 2>/dev/null)"; then
    parse_registry_line "$entry_line"
    project_path="$PARSED_REGISTRY_PATH"
    if [[ -z "$project_template" && -n "$PARSED_REGISTRY_TEMPLATE" ]]; then
      project_template="$PARSED_REGISTRY_TEMPLATE"
    fi
  fi
fi

if [[ -z "$project_path" ]]; then
  display_error "Project path is required"
  exit 1
fi

project_path="$(canonicalize_path "$project_path")"
if [[ ! -d "$project_path" ]]; then
  display_error "Project path does not exist: $project_path"
  exit 1
fi

if [[ -z "$project_name" ]]; then
  project_name="$(basename "$project_path")"
fi
if [[ -z "$project_template" ]]; then
  project_template="$(default_template)"
fi

session_name="$(normalize_session_name "$project_name")"

if tmux_session_exists "$session_name"; then
  switch_to_session "$session_name"
  exit 0
fi

create_workspace "$session_name" "$project_path" "$project_template"
switch_to_session "$session_name"
