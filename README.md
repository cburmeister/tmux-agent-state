# tmux-agent-state

Agent state on your tmux window tabs, for people who already live in tmux and
run coding agents in it.

Every window running an agent gets a marker on its tab:

| Tab | State | Meaning |
|---|---|---|
| `3:api ~` (yellow) | working | the agent is running a turn |
| `3:api !` (whole tab red, bold) | blocked | the agent needs you: a permission prompt, a question, or an error |
| `3:api ✓` (green) | done | the agent finished its turn |
| `3:api` | idle | nothing to see |

`blocked` and `done` also ring the pane's bell, so your terminal's bell handling
(badge, notification, tmux `monitor-bell`) keeps working. Looking at a `done`
window acknowledges it, the same way tmux clears a bell flag. Want a desktop
notification too? Plug in your own notifier with `@agent_state_notify`, see
[Options](#options).

State comes from the agent's own lifecycle events, not from reading the screen.
`blocked` fires on the actual permission prompt.

Requires tmux >= 3.2 — what Ubuntu 22.04's apt and any recent Homebrew already ship.

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

| Agent | Adapter install | Notes |
|---|---|---|
| Claude Code | `claude plugin marketplace add cburmeister/tmux-agent-state && claude plugin install tmux-agent-state@cburmeister` | all six words |
| Claude Code → other models (`ANTHROPIC_BASE_URL`, Ollama, ...) | same, the hooks are Claude Code's, not the model's | |
| Codex CLI | one line in `~/.codex/config.toml`, see [adapters/codex/](adapters/codex/) | `done` only: Codex fires no other external event |
| Gemini CLI | merge [adapters/gemini/settings-hooks.json](adapters/gemini/settings-hooks.json) into `~/.gemini/settings.json`, see [adapters/gemini/](adapters/gemini/) | |
| OpenCode | copy [one file](adapters/opencode/tmux-agent-state.js) into `~/.config/opencode/plugins/`, see [adapters/opencode/](adapters/opencode/) | |
| pi | `pi install git:github.com/cburmeister/tmux-agent-state` | no `blocked`: pi fires no event for it |
| Cursor CLI | not yet possible | Cursor's hooks fire in the IDE, but `cursor-agent` only fires the shell-execution pair — no lifecycle events to map |

Running more than one agent? Install more than one adapter. The tabs don't care
which is which. Every adapter is a thin mapping onto the same six words —
[adapters/README.md](adapters/README.md) has the contract if yours is missing.

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
hook, binds the triage key, and publishes the script's location as
`@agent_state_script`. Every edit is content-checked. They happen once and
self-heal if you reload your config.

Visiting a window acknowledges it. `done` panes go back to idle, panes no longer
running an agent lose their state, `working` and `blocked` panes are left alone.

An adapter maps the agent's lifecycle events to those six words and calls the
script. That is the whole contract, see [adapters/README.md](adapters/README.md).
The Claude Code adapter is a Claude Code plugin (`.claude-plugin/`,
`hooks/hooks.json`) mapping `SessionStart` to `idle`, `UserPromptSubmit` and
`PostToolUse` to `working`, `PermissionRequest`, `PreToolUse(AskUserQuestion)`,
`Notification(permission_prompt|elicitation_dialog|agent_needs_input)` and
`StopFailure` to `blocked`, `Stop` to `done`, `Notification(idle_prompt)` to
`remind`, and `SessionEnd` to `clear`. It lives at the repo root because the
plugin format requires it there.

If an adapter runs before the tmux plugin has (or you skipped step 1), the
script performs setup itself on first call. Nothing breaks, you just didn't
choose when it happened. Updating an adapter takes effect in the running tmux
server on its next event, a newer copy of the script replaces what an older one
set up. No reason to restart tmux.

## Triage: go to whatever needs you

`prefix` + `a` is bound for you at install. It goes straight to the agent that
most needs you: `blocked` before `done`, and among those, the one waiting
longest. No menu, no popup, nothing to read. If nothing needs you it says so
and stays put.

Panes are matched with the same test the tabs use, so the key and the tab bar
can never disagree, and it crosses sessions.

<details>
<summary><code>jump</code>, the 0.3.x binding</summary>

`jump` still works, unchanged: straight to the first `blocked` pane, else the
first `done` one, no UI ever. It is kept so existing configs keep working.
`pick` supersedes it and behaves identically when only one agent needs you, so
you can drop the binding below and use `prefix` + `a` instead.

```tmux
bind b run-shell '"$(tmux show -gv @agent_state_script)" jump'
```
</details>

## Options

Global options in `.tmux.conf`, read at setup.

```tmux
# Each state's glyph and colour, used everywhere that state is drawn: the tab marker,
# the whole-tab styles, and (unless overridden below) the pane border. Defaults shown.
# Change an option and the running server re-renders on the next agent event; no restart.
set -g @agent_state_glyph_blocked '!'
set -g @agent_state_glyph_working '~'
set -g @agent_state_glyph_done    '✓'
set -g @agent_state_style_blocked 'fg=red'      # any tmux style; space-separate attributes
set -g @agent_state_style_working 'fg=yellow'
set -g @agent_state_style_done    'fg=green'

# Or replace the whole tab marker. Default shown (built from the glyphs and styles above):
# worst state across the window's panes.
set -g @agent_state_marker '#{?#{m:*blocked*,#{P:#{@agent_state} }},#[fg=red bold] !,#{?#{m:*working*,#{P:#{@agent_state} }},#[fg=yellow] ~,#{?#{m:*done*,#{P:#{@agent_state} }},#[fg=green] ✓,}}}'

# Process names that count as "an agent is running in this pane". Default shown.
set -g @agent_state_processes 'claude|node|bun|codex|gemini|opencode|pi'

# How much of the tab takes the state colour. Default "attention": the whole tab goes red
# when blocked, other states show only the glyph. "colour": whole tab for every state.
# "marker": glyph only.
set -g @agent_state_tabs attention

# Ring the terminal bell on blocked/done. Default on.
set -g @agent_state_bell off

# What an idle reminder (Claude's idle_prompt, ~60s after finishing) re-rings for.
# Default "blocked": a stalled agent gets a second bell; a finished one is already green.
set -g @agent_state_remind done   # or off

# Run your own command when a pane enters a state. Unset by default. The plugin ships no
# notifier, you plug in the one you already have. Three that work as written:
set -g @agent_state_notify 'terminal-notifier -title "#{session_name}:#{window_name}" -message "agent is $AGENT_STATE"'    # macOS
set -g @agent_state_notify 'osascript -e "display notification \"agent is $AGENT_STATE\" with title \"#{window_name}\""'   # macOS, nothing to install
set -g @agent_state_notify 'notify-send "#{session_name}:#{window_name}" "agent is $AGENT_STATE"'                          # Linux

# Which states fire it. Default shown; space separated, any of working/blocked/done, or off.
set -g @agent_state_notify_states 'blocked done'

# The prefix key bound to pick at install. Default "a"; "off" binds nothing.
set -g @agent_state_key b

# Colour pane borders by state. Default on where tmux supports per-pane border
# styles (probed at setup; older tmux gets the tabs only).
set -g @agent_state_borders off

# Border style per state. Default: the @agent_state_style_* options above.
set -g @agent_state_border_blocked 'fg=red'
set -g @agent_state_border_working 'fg=yellow'
set -g @agent_state_border_done    'fg=green'
```

`@agent_state_notify` fires on the *transition* into a state, not on every event.
A turn's worth of tool calls is `working -> working` and stays silent; a retried
permission prompt is `blocked -> blocked` and stays silent too. The command runs
under `sh`, backgrounded by tmux, so a notifier that hangs for ten seconds never
delays the agent. It gets:

| | |
|---|---|
| `$AGENT_STATE` | the state just entered |
| `$AGENT_STATE_PREV` | the state it came from, empty if the pane had none |
| `$AGENT_STATE_PANE` | the pane id, e.g. `%7` |
| `#{...}` | any tmux format, resolved against that pane: `#{window_name}`, `#{session_name}`, `#{pane_current_path}`, ... |

The bell and the notify command are independent: you can have the bell only (the
default), a notifier only (`@agent_state_bell off`), both, or neither. Over SSH,
prefer the bell. The notify command runs on the machine tmux runs on, so a
desktop notifier there pops up on the *remote* machine; the bell travels down the
connection to your own terminal.

If your `window-status-format` already contains `@agent_state` (you hand-wired
it), the formats are left alone. `#{P:#{@agent_state} }` is every pane's state
in the window, space separated. Build on that.

## Doctor

Something not rendering?

```bash
"$(tmux show -gv @agent_state_script)" doctor
```

prints what the plugin knows: tmux version, where the script is published, whether
the marker, ack hook, and key are wired (including whether a theme is hiding the
marker at session scope), and how many panes are reporting. Exits non-zero if
something needs fixing, and says what.

## Uninstall

```bash
"$(tmux show -gv @agent_state_script)" uninstall
```

undoes everything in the running server: formats, hook, key, pane state,
borders, published options. Your config files are never touched, so
also remove the `@plugin` line and the adapters you installed.

## Limits

- Themes that set the status formats at session or window scope override the
  global option the plugin edits. The marker won't show there (`doctor` warns);
  the pane borders still work.
- If an agent finishes while you're already in that window, the tab shows ✓
  until you switch away and back, or type. Intentional.
- `blocked` is only as precise as the agent's own permission event.
- Denying a permission fires no event, so a pane stays `blocked` until the
  agent's next tool call or the end of its turn.

## Testing

```bash
test/run.sh                 # isolated tmux server, never touches yours. Needs bash + tmux
INTEGRATION=1 test/run.sh   # also runs a real `claude -p` with --plugin-dir
```

Ensure the last line reads `fail=0`.

## Why this one?

There are other tmux agent monitors, and good ones. This one makes three bets
the others don't, together:

- **No dependencies, no daemon.** bash and tmux, nothing else: no fzf, no
  Python, no Node runtime, no downloaded Rust binary, no background poller.
  Everything renders through tmux's own formats and hooks, and the hot path
  costs a handful of tmux calls per *event*, zero per second.
- **Events, not screen scraping.** State comes from each agent's own lifecycle
  hooks, so `blocked` fires on the actual permission prompt, not on a regex
  recognising a spinner — and it can't break when the agent's TUI changes.
- **One plugin, any agent.** Adapters for Claude Code, Codex, Gemini CLI,
  OpenCode, and pi ship in-repo, and the whole adapter contract is "call one
  script with one word", so the next agent is an afternoon, not a fork.

[Herdr](https://herdr.dev) is a second multiplexer with agent state built in. If
you don't use tmux, use it. If you do, this is the same feature without leaving
tmux.
