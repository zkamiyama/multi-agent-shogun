# Communication Protocol

## Runtime Agent Vocabulary (CRITICAL)

In this repository, the words **軍師**, **家老**, **足軽**, **Gunshi**,
**Karo**, and **Ashigaru** always refer to the already-running
Multi-Agent-Shogun runtime agents in the mux sessions listed above.

When the Lord explicitly uses Multi-Agent-Shogun role vocabulary, interpret it
as an instruction to use the Multi-Agent-Shogun YAML + mailbox system, **not**
as an instruction to substitute Codex internal sub-agents for those roles:

- 「軍師に分析させて」 / 「Gunshiにレビューさせて」
- 「家老に任せて」 / 「Karoに振って」
- 「足軽にやらせて」 / 「Ashigaruに実装させて」
- 「軍師・家老・足軽で分担して」

Required routing:

| Lord wording | Meaning | Required action |
|--------------|---------|-----------------|
| 軍師 / Gunshi | runtime `gunshi` pane | Write `queue/tasks/gunshi.yaml`, then `bash scripts/inbox_write.sh gunshi ...` |
| 家老 / Karo | runtime `karo` pane | Write/append `queue/shogun_to_karo.yaml`, then `bash scripts/inbox_write.sh karo ...` |
| 足軽 / Ashigaru | runtime `ashigaruN` panes | Karo assigns `queue/tasks/ashigaruN.yaml`, then `bash scripts/inbox_write.sh ashigaruN ...` |

**Do NOT spawn Codex internal sub-agents** for these words. Codex internal
sub-agents are separate temporary tool agents and are not part of the
Multi-Agent-Shogun chain of command.

Codex internal sub-agents are still allowed for ordinary work when the received
task is splittable and internal delegation is effective (for example parallel
code exploration, independent implementation slices, or verification). They
must not replace a requested runtime Gunshi/Karo/Ashigaru action.

Use Codex internal sub-agent tools when:
- the Lord explicitly says 「Codex internal sub-agent」「Codex内のsubagent」
  「spawn_agent tool」「このチャット内で一時sub-agentをspawnして」; or
- no Multi-Agent-Shogun role vocabulary is used, and internal delegation is the
  most effective way to complete the task.

If both interpretations seem possible, default the named role words to
Multi-Agent-Shogun runtime agents, and use internal sub-agents only for
additional helper work that does not replace the requested runtime-agent
message.

## Mailbox System (inbox_write.sh)

Agent-to-agent communication uses file-based mailbox:

```bash
bash scripts/inbox_write.sh <target_agent> "<message>" <type> <from>
```

Examples:
```bash
# Shogun → Karo
bash scripts/inbox_write.sh karo "cmd_048を書いた。実行せよ。" cmd_new shogun

# Ashigaru → Karo
bash scripts/inbox_write.sh karo "足軽5号、任務完了。報告YAML確認されたし。" report_received ashigaru5

# Karo → Ashigaru
bash scripts/inbox_write.sh ashigaru3 "タスクYAMLを読んで作業開始せよ。" task_assigned karo
```

Delivery is handled by `inbox_watcher.sh` (infrastructure layer).
**Agents NEVER call backend input commands directly** (`tmux send-keys`, `zellij action write`, `zellij action paste`, etc.). Use `inbox_write.sh`; infrastructure routes wakeups through the mux adapter.

**Delivery complete definition**: `inbox_write.sh` success means the message was persisted, not that the target processed it. Treat delivery as complete only when one of these is observed after the message timestamp:
- target inbox unread count returns to 0; or
- the target's task/report/status advances.

Karo, Shogun, and `stall_detector.sh` observe completion from YAML state. Do not use `inbox_write.sh` exit status as a processing/completion signal.

## Delivery Mechanism

Two layers:
1. **Message persistence**: `inbox_write.sh` writes to `queue/inbox/{agent}.yaml` with flock. Guaranteed.
2. **Wake-up signal**: `inbox_watcher.sh` detects file change via `inotifywait` → wakes agent:
   - **Priority 1**: Agent self-watch (agent's own `inotifywait` on its inbox) → no nudge needed
   - **Priority 2**: mux adapter input — short nudge only (text and Enter sent separately, 0.3s gap)

The nudge is minimal: `inboxN` (e.g. `inbox3` = 3 unread). That's it.
**Agent reads the inbox file itself.** Message content never travels through the terminal mux — only a short wake-up signal.

Safety note (shogun):
- If the Shogun pane is active with an attached client (the Lord may be typing), `inbox_watcher.sh` must not inject any automatic keystrokes. Use mux metadata/status APIs only.
- Escalation keystrokes (`Escape×2`, context reset, `C-u`, plain `inboxN` + Enter) must be suppressed for shogun to avoid clobbering human input.
- Karo/Gunshi/Ashigaru active-attached exception: only when the pane is clean-idle, not busy, unread is stale, and the final pre-send check still passes may the watcher send plain `inboxN` + Enter. No Escape/context-reset/C-u in active-attached panes.
- If an Ashigaru `task_assigned` context reset is skipped because the pane is active-attached, any later plain `inboxN` + Enter is delivery only; it is not a fresh context reset guarantee.

Duplicate resend rule:
- Use `DEDUP_KEY` or a stable task/cmd token when resending the same instruction.
- Duplicate resend must not grow unread without bound. Re-sent duplicates should be coalesced by dedupe metadata or bounded by the same task/cmd token.
- Karo/Gunshi/Ashigaru stale unread is visible through `stall_detector` kind `agent_unread_unprocessed`.

Special cases (CLI commands sent through the mux adapter / compatibility layer):
- `type: clear_command` → sends context reset command (Claude/Copilot/Kimi: `/clear`, Codex/OpenCode: `/new`)
- `type: model_switch` → sends the /model command

## Agent Self-Watch Phase Policy (cmd_107)

Phase migration is controlled by watcher flags:

- **Phase 1 (baseline)**: `process_unread_once` at startup + `inotifywait` event-driven loop + timeout fallback.
- **Phase 2 (normal nudge off)**: `disable_normal_nudge` behavior enabled (`ASW_DISABLE_NORMAL_NUDGE=1` or `ASW_PHASE>=2`).
- **Phase 3 (final escalation only)**: `FINAL_ESCALATION_ONLY=1` (or `ASW_PHASE>=3`) so normal mux nudge `inboxN` is suppressed; escalation lane remains for recovery.

Read-cost controls:

- `summary-first` routing: unread_count fast-path before full inbox parsing.
- `no_idle_full_read`: timeout cycle with unread=0 must skip heavy read path.
- Metrics hooks are recorded: `unread_latency_sec`, `read_count`, `estimated_tokens`.

**Escalation** (when nudge is not processed):

| Elapsed | Action | Trigger |
|---------|--------|---------|
| 0〜2 min | Standard pty nudge | Normal delivery |
| 2〜4 min | Escape×2 + nudge | Copilot/Kimi use Escape×2 + Ctrl-C + nudge. Claude/Codex/OpenCode use a plain nudge instead |
| 4 min+ | Context reset sent (max once per unread batch; skipped for Codex non-command agents) | Force session reset + YAML re-read |

Destructive recovery guardrails:
- Never send destructive recovery to an active-attached pane.
- Shogun remains hard-blocked from automatic destructive recovery because the Lord may be typing.
- Karo/Gunshi command-layer destructive recovery, including Codex/OpenCode `/new`, is allowed only when all are true: not active-attached, not busy, stale unread exists, and recovery has not already been sent for that unread batch.
- Ashigaru task-assignment context reset remains allowed only when not active-attached; active-attached Ashigaru panes may receive clean-idle plain nudge only, never destructive recovery.
- Codex non-command agents continue to skip automatic destructive recovery except for the existing non-active Ashigaru task-assignment context reset path.
- For unchanged unread batches, destructive recovery is once per unread batch; use plain nudge afterward.

## Inbox Processing Protocol (karo/ashigaru/gunshi)

When you receive `inboxN` (e.g. `inbox3`):
1. `Read queue/inbox/{your_id}.yaml`
2. Find all entries with `read: false`
3. Process each message according to its `type`
4. Update each processed entry: `read: true` (use Edit tool)
5. Resume normal workflow

### MANDATORY Post-Task Inbox Check

**After completing ANY task, BEFORE going idle:**
1. Read `queue/inbox/{your_id}.yaml`
2. If any entries have `read: false` → process them
3. Only then go idle

This is NOT optional. If you skip this and a redo message is waiting,
you will be stuck idle until the next nudge escalation or task reassignment.

## Redo Protocol

When Karo determines a task needs to be redone:

1. Karo writes new task YAML with new task_id (e.g., `subtask_097d` → `subtask_097d2`), adds `redo_of` field
2. Karo sends `clear_command` type inbox message (NOT `task_assigned`)
3. inbox_watcher delivers context reset to the agent（Claude/Copilot/Kimi: `/clear`, Codex/OpenCode: `/new`）→ session reset
4. Agent recovers via Session Start procedure, reads new task YAML, starts fresh

Race condition is eliminated: context reset wipes old context. Agent re-reads YAML with new task_id.

## Report Flow (interrupt prevention)

| Direction | Method | Reason |
|-----------|--------|--------|
| Ashigaru/Gunshi → Karo | Report YAML + inbox_write | File-based notification |
| Karo → Shogun/Lord | dashboard.md update only | **inbox to shogun FORBIDDEN** — prevents interrupting Lord's input |
| Karo → Gunshi | YAML + inbox_write | Strategic task delegation |
| Top → Down | YAML + inbox_write | Standard wake-up |

## File Operation Rule

**Always Read before Write/Edit.** Claude Code rejects Write/Edit on unread files.

## Inbox Communication Rules

### Sending Messages

```bash
bash scripts/inbox_write.sh <target> "<message>" <type> <from>
```

**No sleep interval needed.** No sender-side retry loop needed. Multiple sends can be done in rapid succession — flock handles concurrency.

### Report Notification Protocol

After writing report YAML, notify Karo:

```bash
bash scripts/inbox_write.sh karo "足軽{N}号、任務完了でござる。報告書を確認されよ。" report_received ashigaru{N}
```

That's it. No sender-side sleep loop or retry is needed.
`inbox_write.sh` guarantees persistence and may trigger best-effort supervisor self-heal. Processing completion is observed later from unread count or task/report/status progress, not from the write command itself.
