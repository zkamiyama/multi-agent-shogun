# OpenCode CLI Tools

This section describes OpenCode-specific tools, rules loading, and session-control behavior.

## Overview

OpenCode starts the TUI by default with `opencode`, can run headless work with `opencode run`, and accepts an initial bootstrap message via `--prompt` on both interactive and run flows.

- **Launch**: `OPENCODE_CONFIG_CONTENT='{"permission":"allow"}' opencode --model provider/model --prompt <bootstrap-prompt>`
- **Headless mode**: `opencode run [message...]` for non-interactive automation
- **Model format**: `provider/model` such as `openai/gpt-5.4` or `moonshot/kimi-k2.5`
- **Stats**: `opencode stats` shows token usage and cost statistics

## Built-in tools

OpenCode provides built-in tools including `bash`, `read`, `edit`, `write`, `grep`, `glob`, `list`, `apply_patch`, `skill`, `todowrite`, `webfetch`, `websearch`, and `question`.

Guidelines:

1. **Read before edit**: inspect relevant files before changing them
2. **Use focused tools**: prefer `read`/`grep`/`glob` over shelling out for routine inspection
3. **Use `skill` for reusable workflows**: OpenCode loads `SKILL.md` definitions on demand
4. **Permissions in this repo**: OpenCode launches with a repo-pinned `OPENCODE_CONFIG_CONTENT` that allows normal tool use but denies direct writes to queue/instruction auto-load files; keep those files edited only through the repository scripts
5. **Session titles**: the bootstrap prompt starts with `[Session Title: <Role>'s pane]` so OpenCode's auto-generated session title stays role-identifiable and unmistakable
6. **tmux key handling**: use the repository-provided `config/opencode-tui.json` via `OPENCODE_TUI_CONFIG` so tmux automation sees stable keybinds
7. **Keybind policy**: `app_exit` is disabled in that file, `session_interrupt` is `escape`, and `input_clear` is `ctrl+c`; do not rely on global user keybinds for these actions

## Instructions and rules

OpenCode reads project instructions from `AGENTS.md` and supports Claude-compatible fallbacks such as `CLAUDE.md` when `AGENTS.md` is absent. Additional instruction files can be layered via the `instructions` field in `opencode.json`.

For this repository:

1. `AGENTS.md` remains the auto-load root rule file
2. The launch bootstrap prompt must point the agent to the generated role-specific OpenCode instruction file
3. The role-specific generated file is the source of truth for CLI-specific operating details

## Session control

OpenCode TUI supports `/new` (alias `/clear`) to start a new session, `/compact` to summarize context, `/sessions` to switch/resume sessions, and `/models` to inspect available models.

Operational rules for this repository:

1. **Bootstrap first**: at session start, identify the role, then read task/inbox state and the generated OpenCode role file
2. **Deterministic startup prompt**: startup prompt text must stay stable per role so automation stays reliable
3. **Context reset**: automation should send `/new`
4. **Model changes**: treat model changes as relaunch-only in tmux automation even though OpenCode can inspect models interactively

## Config, providers, and permissions

OpenCode merges config from remote defaults, `~/.config/opencode/opencode.json`, project `opencode.json`, `.opencode/` directories, and environment overrides. Providers and models are configured with `provider/model` IDs, and permissions are controlled through the `permission` config.

Key points:

- `permission` controls whether tools are `allow`, `ask`, or `deny`
- `OPENCODE_CONFIG_CONTENT` is the documented runtime override path; this repository uses it to allow normal tool use while denying direct writes to queue/dashboard/instruction auto-load files
- `websearch` is available when using the OpenCode provider or when `OPENCODE_ENABLE_EXA` is enabled
- MCP servers are configured in `opencode.json` and become normal tools once enabled
- Skills are discovered from `.opencode/skills/`, `.claude/skills/`, and compatible global paths

## Session control notes

| Action | OpenCode behavior |
|--------|-------------------|
| New task | Start with `--prompt` bootstrap text |
| Context reset | Use `/new` |
| Model change | Restart with a new `opencode --model ...` launch |
| Instruction loading | Read `AGENTS.md`, then the generated role-specific OpenCode instruction file |
| Usage review | `opencode stats` for token and cost statistics |
