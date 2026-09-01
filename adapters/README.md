# Adapters

`scripts/agent-state.sh` is the whole interface between tmux and any agent. An
adapter is whatever a given agent needs in order to call it with one word:

| Word | When |
|---|---|
| `idle` | session started |
| `working` | user submitted a prompt, or a tool call finished |
| `blocked` | agent is waiting on the human (permission, question, error) |
| `done` | agent finished its turn |
| `remind` | agent has been idle a while, re-ring the bell if still blocked/done |
| `clear` | session ended |

The script exits 0 and prints nothing, no-ops outside tmux, configures tmux
itself on first call, is idempotent, and tracks state per pane (the window tab
rolls up the worst pane). Adapters should be equally dumb: no state, no tmux
calls, just map the agent's events to a word.

## Finding the script

The tmux plugin publishes the script's location: `tmux show -gv @agent_state_script`.
Adapters call that. Every agent's install then reduces to "install the tmux
plugin, install the adapter", and there is one copy of the core on the machine.

An adapter whose install copies the whole repo (Claude Code plugins,
`pi install git:`, npm) may also carry the script and call its own copy when
`@agent_state_script` is unset. The Claude Code adapter does this so it keeps
working if the user skipped the tmux plugin. Never hard-code a plugin
directory, tpack uses hashed directory names.

## Event mapping per agent

All nine are built. Each adapter's own README carries the install command and
the reasoning behind its mapping. One row per agent; `none` means the agent
fires no event for that word, so the tab simply skips that state.

| Agent | idle | working | blocked | done | remind | clear |
|---|---|---|---|---|---|---|
| Claude Code ([hooks/](../hooks/hooks.json)) | `SessionStart` | `UserPromptSubmit`, `PostToolUse`, `PostToolUseFailure`, `PermissionDenied`, `ElicitationResult` | `PermissionRequest`, `PreToolUse: AskUserQuestion`, `Notification: permission_prompt, elicitation_dialog, agent_needs_input`, `StopFailure` | `Stop` | `Notification: idle_prompt` | `SessionEnd` |
| [Codex CLI](codex/) | none | none | none | `agent-turn-complete` | none | none |
| [Gemini CLI](gemini/) | `SessionStart` | `BeforeAgent`, `AfterTool` | `Notification` | `AfterAgent` | none | `SessionEnd` |
| [OpenCode](opencode/) | `session.created` | `message.updated` (user), `tool.execute.after`, `permission.replied` | `permission.asked`, `session.error` | `session.idle` | none | `session.deleted` |
| [pi](pi/) | `session_start` | `agent_start` | none | `agent_settled` | none | `session_shutdown` |
| [Qwen Code](qwen/) | `SessionStart` | `UserPromptSubmit`, `PostToolUse`, `PostToolUseFailure`, `PermissionDenied` | `PermissionRequest` | `Stop` | none | `SessionEnd` |
| [Copilot CLI](copilot/) | `sessionStart` | `userPromptSubmitted`, `postToolUse`, `postToolUseFailure` | `permissionRequest` | `agentStop` | none | `sessionEnd` |
| [goose](goose/) | `SessionStart` | `UserPromptSubmit`, `PostToolUse`, `PostToolUseFailure` | none | `Stop` | none | `SessionEnd` |
| [Amp](amp/) | `session.start` | `agent.start`, `tool.result` | none | `agent.end` | none | none |

`blocked` is only as good as the agent's own permission event. Map every way
the agent can wait on the human, not just permissions: Claude Code's
`AskUserQuestion` is a tool call, so it needs its own hook or the pane sits at
`working` while the agent waits for an answer.

`test/run.sh` pins every mapping above (`hooks-contract`, and the
`*-adapter-*` checks, which really execute the Codex and Gemini snippets and
load the OpenCode plugin); update the tests and this table together.

## Adding one

1. `adapters/<agent>/`: the agent's native config (`hooks.json`, a TypeScript
   extension, ...) plus a README with that agent's install command.
2. Map events to words per the table and call the script.
3. If the agent's process name isn't in the `@agent_state_processes` default
   (`claude|node|bun|codex|gemini|opencode|pi|qwen|copilot|goose|amp`), add it.
   Otherwise the ack hook treats the window as agent-less and drops its state
   on visit.
4. Add a line to the install table in the top-level README.

The Claude Code adapter lives at the repo root (`.claude-plugin/`, `hooks/`)
rather than under `adapters/`, because the plugin format requires it there.
