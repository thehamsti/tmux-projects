#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

search_script="${SCRIPT_DIR}/search-open-projects.sh"

if ! command -v fzf >/dev/null 2>&1; then
  display_error "fzf is required for the interactive picker"
  exit 1
fi

fzf \
  --disabled \
  --delimiter=$'\t' \
  --with-nth=2,3 \
  --prompt="Open project> " \
  --height="$(fzf_height)" \
  --header="Type to filter already-open tmux project sessions" \
  --bind="start:reload:bash ${search_script} --query ''" \
  --bind="change:reload:bash ${search_script} --query {q}" \
  --preview='printf "%s\n" {3}'
