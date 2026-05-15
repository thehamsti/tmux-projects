#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

build_candidates() {
  bash "${SCRIPT_DIR}/search-open-projects.sh" --query ""
}

if ! command -v fzf >/dev/null 2>&1; then
  tmux choose-tree -s
  exit 0
fi

selection_file="$(mktemp "${TMPDIR:-/tmp}/tmux-projects.selection.XXXXXX")"
trap 'rm -f "$selection_file"' EXIT

if ! build_candidates | grep -q .; then
  display_info "No registered projects or sessions"
  exit 0
fi

if supports_popup; then
  set +e
  tmux display-popup -w 80 -h 20 -E "bash '${SCRIPT_DIR}/pick-open-project.sh' > '${selection_file}'"
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
  tmux command-prompt -p "Open session name:" "switch-client -t %1"
  exit 0
fi

if [[ ! -s "$selection_file" ]]; then
  exit 0
fi

IFS=$'\t' read -r selected_type selected_name _selected_path _selected_url <"$selection_file"

case "$selected_type" in
  session)
    tmux switch-client -t "$selected_name"
    ;;
  *)
    display_error "Unknown picker selection: $selected_type"
    exit 1
    ;;
esac
