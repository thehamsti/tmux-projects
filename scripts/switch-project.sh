#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

build_candidates() {
  local line
  local seen_sessions=""
  local session_name

  while IFS= read -r line || [[ -n "$line" ]]; do
    parse_registry_line "$line"
    printf 'project\t%s\t%s\t%s\n' "$PARSED_REGISTRY_NAME" "$PARSED_REGISTRY_PATH" "$PARSED_REGISTRY_URL"
    seen_sessions+="${PARSED_REGISTRY_NAME}"$'\n'
  done < <(list_registry_entries)

  if ! command -v tmux >/dev/null 2>&1; then
    return 0
  fi

  while IFS= read -r session_name || [[ -n "$session_name" ]]; do
    [[ -z "$session_name" ]] && continue
    if printf '%s' "$seen_sessions" | grep -qxF "$session_name"; then
      continue
    fi
    printf 'session\t%s\t%s\t%s\n' "$session_name" "-" "-"
  done < <(tmux list-sessions -F '#S' 2>/dev/null || true)
}

if ! command -v fzf >/dev/null 2>&1; then
  tmux choose-tree -s
  exit 0
fi

candidate_file="$(mktemp "${TMPDIR:-/tmp}/tmux-projects.candidates.XXXXXX")"
selection_file="$(mktemp "${TMPDIR:-/tmp}/tmux-projects.selection.XXXXXX")"
trap 'rm -f "$candidate_file" "$selection_file"' EXIT

build_candidates >"$candidate_file"
if [[ ! -s "$candidate_file" ]]; then
  display_info "No registered projects or sessions"
  exit 0
fi

if supports_popup; then
  set +e
  tmux display-popup -w 80 -h 20 -E "bash -lc 'fzf --delimiter=\"\t\" --with-nth=1,2,3 --prompt=\"Project> \" --height=\"$(fzf_height)\" < \"$candidate_file\" > \"$selection_file\"'"
  popup_status=$?
  set -e

  if [[ $popup_status -eq 130 || $popup_status -eq 1 ]]; then
    exit 0
  fi
  if [[ $popup_status -ne 0 ]]; then
    display_error "Project switcher failed (status $popup_status)"
    exit 1
  fi
else
  tmux command-prompt -p "Project or session name:" "run-shell \"bash '${SCRIPT_DIR}/open-project.sh' --name %1\""
  exit 0
fi

if [[ ! -s "$selection_file" ]]; then
  exit 0
fi

IFS=$'\t' read -r selected_type selected_name selected_path _selected_url <"$selection_file"

case "$selected_type" in
  project)
    bash "${SCRIPT_DIR}/open-project.sh" --name "$selected_name" --path "$selected_path"
    ;;
  session)
    tmux switch-client -t "$selected_name"
    ;;
  *)
    display_error "Unknown picker selection: $selected_type"
    exit 1
    ;;
esac
