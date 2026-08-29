# tmux-agent-state

Agent state on your tmux window tabs, for people who already live in tmux and
run coding agents in it.

Every window running an agent gets a marker on its tab:

| Tab | State | Meaning |
|---|---|---|
| `3:api ~` (yellow) | working | the agent is running a turn |
| `3:api !` (red, bold) | blocked | the agent needs you: a permission prompt, a question, or an error |
| `3:api ✓` (green) | done | the agent finished its turn |
| `3:api` | idle | nothing to see |

`blocked` and `done` also ring the pane's bell, so your terminal's bell handling
(badge, notification, tmux `monitor-bell`) keeps working. Looking at a `done`
window acknowledges it, the same way tmux clears a bell flag.

State comes from the agent's own lifecycle events, not from reading the screen.
`blocked` fires on the actual permission prompt.

Requires tmux >= 3.2 (Ubuntu 22.04 or newer, any current Homebrew).

## Install

Two steps, the same for every agent.

### 1. The tmux plugin

Add to `.tmux.conf`, then `prefix` + `I`:

```tmux
set -g @plugin 'cburmeister/tmux-agent-state'
```

Works with [tpack](https://github.com/tmuxpack/tpack) (`brew install tpack`) or
[TPM](https://github.com/tmux-plugins/tpm). This sets up the tab rendering and
the ack behaviour. It knows nothing about agents yet.

### 2. Your agent's adapter

The adapter tells the tmux plugin what the agent is doing. Install it the way
that agent installs things:

| Agent | Adapter install | Status |
|---|---|---|
| Claude Code | `claude plugin marketplace add cburmeister/tmux-agent-state && claude plugin install tmux-agent-state@cburmeister` | built, tested |
| Claude Code → other models (`ANTHROPIC_BASE_URL`, Ollama, ...) | same, the hooks are Claude Code's, not the model's | works |
| Codex CLI | none yet | see [adapters/](adapters/README.md) |
| Gemini CLI | none yet | |
| OpenCode | none yet | |
| Pi | none yet | |

Running more than one agent? Install more than one adapter. The tabs don't care
which is which.

Claude Code notes: new sessions pick it up immediately, running sessions need
`/reload-plugins`. `claude --bare` skips plugins entirely so bare sessions don't
report.

## How it works

`scripts/agent-state.sh` takes one word (`idle`, `working`, `blocked`, `done`,
`remind`, `clear`) and stores it in a tmux pane option, `@agent_state`. Two
things render it:

- The window tab shows the worst state across the window's panes. `blocked`
  beats `working` beats `done`. Two agents in one window (a queue-draining loop
  and a one-off session, say) can't overwrite each other's tab. The tab answers
  "does this window need me?"
- Each agent pane's border is coloured by its own state (red, yellow, green), so
  once you're in the window you can see which pane is which.

The tmux plugin runs the script's `setup` at tmux startup. Setup appends the tab
marker to your existing `window-status-format` and `window-status-current-format`
(your theme is untouched, the marker is a suffix), adds a `session-window-changed`
hook, and publishes the script's location as `@agent_state_script`. Both edits
are content-checked. They happen once and self-heal if you reload your config.

Visiting a window acknowledges it. `done` panes go back to idle, panes no longer
running an agent lose their state, `working` and `blocked` panes are left alone.

An adapter maps the agent's lifecycle events to those six words and calls the
script. That is the whole contract, see [adapters/README.md](adapters/README.md).
The Claude Code adapter is a Claude Code plugin (`.claude-plugin/`,
`hooks/hooks.json`) mapping `SessionStart` to `idle`, `UserPromptSubmit` and
`PostToolUse` to `working`, `Notification(permission_prompt)` and `StopFailure`
to `blocked`, `Stop` to `done`, `Notification(idle_prompt)` to `remind`, and
`SessionEnd` to `clear`. It lives at the repo root because the plugin format
requires it there.

If an adapter runs before the tmux plugin has (or you skipped step 1), the
script performs setup itself on first call. Nothing breaks, you just didn't
choose when it happened. Updating an adapter takes effect in the running tmux
server on its next event, a newer copy of the script replaces what an older one
set up. No reason to restart tmux.

## Jump to whatever needs you

```tmux
bind b run-shell '"$(tmux show -gv @agent_state_script)" jump'
```

`prefix` + `b` selects the first window with a `blocked` pane, else the first
with a `done` one, else tells you nothing needs you.

## Options

Global options in `.tmux.conf`, read at setup.

```tmux
# The marker appended to window tabs. Default shown: worst state across the window's panes.
set -g @agent_state_marker '#{?#{m:*blocked*,#{P:#{@agent_state} }},#[fg=red bold] !,#{?#{m:*working*,#{P:#{@agent_state} }},#[fg=yellow] ~,#{?#{m:*done*,#{P:#{@agent_state} }},#[fg=green] ✓,}}}'

# Process names that count as "an agent is running in this pane". Default shown.
set -g @agent_state_processes 'claude|node|codex|gemini|opencode|pi'

# Colour pane borders by state. Default on where tmux supports per-pane border
# styles (probed at setup; older tmux gets the tabs only).
set -g @agent_state_borders off

# Border style per state. Defaults shown.
set -g @agent_state_border_blocked 'fg=red'
set -g @agent_state_border_working 'fg=yellow'
set -g @agent_state_border_done    'fg=green'
```

If your `window-status-format` already contains `@agent_state` (you hand-wired
it), the formats are left alone. `#{P:#{@agent_state} }` is every pane's state
in the window, space separated. Build on that.

## Limits

- Themes that set the status formats at session or window scope override the
  global option the plugin edits. The marker won't show there.
- If an agent finishes while you're already in that window, the tab shows ✓
  until you switch away and back, or type. Intentional.
- `blocked` is only as precise as the agent's own permission event.

## Testing

```bash
test/run.sh                 # isolated tmux server, never touches yours. Needs bash + tmux
INTEGRATION=1 test/run.sh   # also runs a real `claude -p` with --plugin-dir
```

Ensure the last line reads `fail=0`.

## Why not Herdr?

[Herdr](https://herdr.dev) is a second multiplexer with agent state built in. If
you don't use tmux, use it. If you do, this is the same feature without leaving
tmux. It uses the agents' own events rather than screen matching, so `blocked`
doesn't depend on a regex recognising the prompt.
