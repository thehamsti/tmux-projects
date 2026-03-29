#!/usr/bin/env bash
set -uo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

set_default() {
  local option_name="$1"
  local default_value="$2"
  local current_value

  current_value="$(tmux show-option -gv "$option_name" 2>/dev/null || true)"
  if [[ -z "$current_value" ]]; then
    tmux set-option -g "$option_name" "$default_value" 2>/dev/null || true
  fi
}

set_default "@tmux-projects-key-add" "S"
set_default "@tmux-projects-key-switch" "f"
set_default "@tmux-projects-registry-file" "$HOME/.config/tmux-projects/projects.tsv"
set_default "@tmux-projects-projects-dir" "$HOME/projects"
set_default "@tmux-projects-template" "default"
set_default "@tmux-projects-fzf-height" "40%"
set_default "@tmux-projects-use-popup" "on"
set_default "@tmux-projects-scan-paths" ""

ADD_KEY="$(tmux show-option -gv @tmux-projects-key-add 2>/dev/null || printf 'S')"
SWITCH_KEY="$(tmux show-option -gv @tmux-projects-key-switch 2>/dev/null || printf 'f')"

tmux bind-key "$ADD_KEY" run-shell "bash '${CURRENT_DIR}/scripts/add-project.sh'" 2>/dev/null || true
tmux bind-key "$SWITCH_KEY" run-shell "bash '${CURRENT_DIR}/scripts/switch-project.sh'" 2>/dev/null || true
