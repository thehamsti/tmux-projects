#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

input_value=""
project_name=""
project_path=""
project_template=""
project_notes=""
no_open=0
interactive=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input)
      input_value="${2-}"
      shift 2
      ;;
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
    --notes)
      project_notes="${2-}"
      shift 2
      ;;
    --no-open)
      no_open=1
      shift
      ;;
    --interactive)
      interactive=1
      shift
      ;;
    *)
      display_error "Unknown argument: $1"
      exit 1
      ;;
  esac
done

if [[ -z "$input_value" && $interactive -eq 0 ]]; then
  if supports_popup; then
    tmux display-popup -w 70 -h 12 -E "bash '${SCRIPT_DIR}/add-project.sh' --interactive"
    exit 0
  fi

  tmux command-prompt -p "Repo URL or local dir:" "run-shell \"bash '${SCRIPT_DIR}/add-project.sh' --input %1\""
  exit 0
fi

if [[ $interactive -eq 1 ]]; then
  printf 'Repo URL or local path: '
  IFS= read -r input_value
fi

if [[ -z "$input_value" ]]; then
  display_info "No project provided"
  exit 0
fi

if [[ -z "$project_template" ]]; then
  project_template="$(default_template)"
fi

repo_url=""

if is_repo_url "$input_value"; then
  repo_url="$input_value"

  if [[ -z "$project_name" ]]; then
    project_name="$(infer_name_from_repo_url "$repo_url")"
  fi

  if [[ -z "$project_path" ]]; then
    project_path="$(projects_dir)/$project_name"
  fi

  project_path="$(canonicalize_path "$project_path")"
  mkdir -p "$(dirname "$project_path")"

  if [[ -d "$project_path" ]]; then
    if [[ -d "$project_path/.git" ]]; then
      existing_remote="$(git -C "$project_path" remote get-url origin 2>/dev/null || true)"
      if [[ -n "$existing_remote" && "$existing_remote" != "$repo_url" ]]; then
        display_error "Target already exists with a different origin: $project_path"
        exit 1
      fi
    else
      display_error "Target exists and is not a git repository: $project_path"
      exit 1
    fi
  else
    git clone "$repo_url" "$project_path"
  fi
else
  project_path="$(canonicalize_path "${project_path:-$input_value}")"
  if [[ ! -d "$project_path" ]]; then
    display_error "Directory does not exist: $project_path"
    exit 1
  fi

  if [[ -z "$project_name" ]]; then
    project_name="$(basename "$project_path")"
  fi
fi

if [[ -z "$project_name" ]]; then
  display_error "Project name could not be inferred"
  exit 1
fi

upsert_registry_entry "$project_name" "$repo_url" "$project_path" "$project_template" "$project_notes"
display_info "Registered ${project_name}"

if [[ $no_open -eq 0 ]]; then
  bash "${SCRIPT_DIR}/open-project.sh" \
    --name "$project_name" \
    --path "$project_path" \
    --template "$project_template"
fi
