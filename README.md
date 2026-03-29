# tmux-projects

`tmux-projects` is a tmux plugin for managing named project workspaces with TPM.

Core flows:

- `prefix + S` to register a repo URL or existing local directory and open it as a workspace
- `prefix + f` to search registered projects quickly and switch to them

Built-in template layout:

- `main` window with a main-vertical 3-pane layout
- `bg` window
- `logs` window

## Install

Add the plugin to your tmux config:

```tmux
set -g @plugin 'thehamsti/tmux-projects'
```

Then reload tmux and install via TPM.

## Default Options

```tmux
set -g @tmux-projects-key-add 'S'
set -g @tmux-projects-key-switch 'f'
set -g @tmux-projects-registry-file '~/.config/tmux-projects/projects.tsv'
set -g @tmux-projects-projects-dir '~/projects'
set -g @tmux-projects-template 'default'
set -g @tmux-projects-fzf-height '40%'
set -g @tmux-projects-use-popup 'on'
set -g @tmux-projects-scan-paths ''
```

`default` is currently the only built-in template. Setting
`@tmux-projects-template` to any other value will fail when opening a workspace
unless you add matching support in the plugin.

## Registry Format

The registry is a tab-separated file managed by the plugin:

```text
# name	repo_url	local_path	template	notes
dotfiles	https://github.com/example/dotfiles.git	/Users/me/projects/dotfiles	default
```

The registry is authoritative in v1. `prefix + f` searches it first, then falls back to unregistered tmux sessions.

## Usage

### Add a repo from tmux

Press `prefix + S` and enter a repo URL:

```text
https://github.com/example/my-app.git
```

It will:

1. infer the project name from the repo URL
2. clone into `@tmux-projects-projects-dir` if needed
3. upsert the project into the registry
4. create or switch to the tmux workspace

### Register an existing local directory

Press `prefix + S` and enter a local path:

```text
~/projects/existing-app
```

The plugin will register the directory and open it without cloning.

### Search and switch

Press `prefix + f` to open an `fzf` picker inside a tmux popup.

If `fzf` is missing, the plugin falls back to tmux's built-in session chooser.

## Import Existing Directories

To migrate from an older `@project-paths` directory-scan workflow:

```bash
./scripts/import-projects.sh --write
```

By default it reads:

- `@tmux-projects-scan-paths`, if set
- otherwise legacy `@project-paths`, if set
- otherwise `~/projects ~/k16`

Run without `--write` for a dry run.

## Local Validation

```bash
./tests/plugin_test.sh
bash -n tmux-projects.tmux scripts/*.sh scripts/lib/*.sh
shellcheck tmux-projects.tmux scripts/*.sh scripts/lib/*.sh   # if installed
shfmt -d tmux-projects.tmux scripts/*.sh scripts/lib/*.sh     # if installed
```
