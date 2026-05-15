#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

write_changes=0
import_paths=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --paths)
      import_paths="${2-}"
      shift 2
      ;;
    --write)
      write_changes=1
      shift
      ;;
    *)
      display_error "Unknown argument: $1"
      exit 1
      ;;
  esac
done

if [[ -z "$import_paths" ]]; then
  import_paths="$(scan_paths)"
fi

found_any=0
while IFS= read -r directory_path; do
  [[ -z "$directory_path" ]] && continue
  found_any=1
  project_name="$(basename "$directory_path")"

  if [[ $write_changes -eq 1 ]]; then
    upsert_registry_entry "$project_name" "" "$directory_path" "$(default_template)" ""
    printf 'imported\t%s\t%s\n' "$project_name" "$directory_path"
  else
    printf 'dry-run\t%s\t%s\n' "$project_name" "$directory_path"
  fi
done < <(
  TMUX_PROJECTS_SCAN_PATHS="$import_paths" bash -lc '
    source "'"${SCRIPT_DIR}/lib/common.sh"'"
    list_scanned_project_paths
  '
)

if [[ $found_any -eq 0 ]]; then
  display_info "No projects found under: $import_paths"
fi
