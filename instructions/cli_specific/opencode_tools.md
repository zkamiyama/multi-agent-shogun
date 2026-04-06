# OpenCode CLI Tools

This section describes OpenCode-specific tools, rules loading, and session-control behavior.

## Overview

OpenCode starts the TUI by default with `opencode`, can run headless work with `opencode run`, and each agent loads a pre-built definition from `.opencode/agents/<name>.md`, which contains the full system prompt (role instructions, protocol, task flow, forbidden actions) and role-specific permissions baked into the YAML frontmatter at build time.

- **Launch**: `OPENCODE_TUI_CONFIG=<tui-config> opencode --model provider/model --agent <agent_id>`
- **Headless mode**: `opencode run [message...]` for non-interactive automation
- **Model format**: `provider/model` such as `openai/gpt-5.4` or `moonshot/kimi-k2.5`
- **Stats**: `opencode stats` shows token usage and cost statistics

## Built-in tools

OpenCode provides built-in tools including `bash`, `read`, `edit`, `write`, `grep`, `glob`, `list`, `apply_patch`, `skill`, `todowrite`, `webfetch`, `websearch`, and `question`.

Guidelines:

1. **Read before edit**: inspect relevant files before changing them
2. **Use focused tools**: prefer `read`/`grep`/`glob` over shelling out for routine inspection
3. **Use `skill` for reusable workflows**: OpenCode loads `SKILL.md` definitions on demand
4. **Permissions in this repo**: each agent's `.opencode/agents/<name>.md` embeds role-specific file boundaries in its YAML frontmatter (generated from `config/opencode-permissions.yaml` at build time). Shogun is blocked from `queue/reports/*`, Karo is limited to coordination files plus report aggregation, Ashigaru only touch their own task/report pair, and Gunshi reads ashigaru reports while only writing `gunshi_report.yaml`. The `question` tool is allowed only for the Shogun role; other roles have it denied so they do not stall on interactive prompts
5. **tmux key handling**: use the repository-provided `config/opencode-tui.json` via `OPENCODE_TUI_CONFIG` so tmux automation sees stable keybinds
6. **Keybind policy**: `app_exit` is disabled in that file, `session_interrupt` is `escape`, and `input_clear` is `ctrl+c`; do not rely on global user keybinds for these actions

## Instructions and rules

OpenCode reads project instructions from `AGENTS.md` and supports Claude-compatible fallbacks such as `CLAUDE.md` when `AGENTS.md` is absent. Additional instruction files can be layered via the `instructions` field in `opencode.json`.

For this repository:

1. `AGENTS.md` remains the auto-load root rule file
2. Each agent's full instruction set (role, protocol, task flow, forbidden actions) is pre-built in `.opencode/agents/<name>.md` at build time
3. The agent definition file is the source of truth for CLI-specific operating details

## Session control

OpenCode TUI supports `/new` (alias `/clear`) to start a new session, `/compact` to summarize context, `/sessions` to switch/resume sessions, and `/models` to inspect available models.

Operational rules for this repository:

1. **Agent auto-load**: at session start, the agent definition from `.opencode/agents/<name>.md` is loaded automatically, providing role, permissions, and full instructions
2. **Session identification**: the agent should still run `tmux display-message -t "$TMUX_PANE" -p '#{@agent_id}'` to confirm its pane assignment
3. **Context reset**: automation should send `/new`
4. **Model changes**: treat model changes as relaunch-only in tmux automation even though OpenCode can inspect models interactively

## Config, providers, and permissions

OpenCode merges config from remote defaults, `~/.config/opencode/opencode.json`, project `opencode.json`, `.opencode/` directories, and environment overrides. Providers and models are configured with `provider/model` IDs, and permissions are controlled through the `permission` config.

Key points:

- `permission` controls whether tools are `allow`, `ask`, or `deny`
- Role-specific permissions are baked into `.opencode/agents/<name>.md` at build time via `scripts/build_instructions.sh` — no runtime `OPENCODE_CONFIG_CONTENT` needed
- `websearch` is available when using the OpenCode provider or when `OPENCODE_ENABLE_EXA` is enabled
- MCP servers are configured in `opencode.json` and become normal tools once enabled
- Skills are discovered from `.opencode/skills/`, `.claude/skills/`, and compatible global paths

## Session control notes

 (see below)

| Action | OpenCode behavior |
|--------|-------------------|
| New task | `--agent <name>` loads system prompt from `.opencode/agents/<name>.md` |
| Context reset | Use `/new` |
| Model change | Restart with a new `opencode --model ... --agent <name>` launch |
| Instruction loading | `AGENTS.md` (auto) + `.opencode/agents/<name>.md` (auto via `--agent`) |
| Usage review | `opencode stats` for token and cost statistics |
