# Codex CLI adapter

Codex's external hook is `notify` in `~/.codex/config.toml`: an argv array run
when a turn completes, with a JSON payload appended as one final argument.
That is the only event Codex exposes to external programs today
([openai/codex#11808](https://github.com/openai/codex/issues/11808)), so this
adapter maps:

| Codex event | Word |
|---|---|
| `agent-turn-complete` | `done` |

Add to `~/.codex/config.toml`:

```toml
notify = ["sh", "-c", "exec \"$(tmux show -gv @agent_state_script)\" done", "tmux-agent-state"]
```

Nothing to install: the command asks tmux where the tmux plugin published the
script (step 1 in the top-level README) and calls it. Outside tmux, or with the
tmux plugin missing, `sh` fails quietly and Codex never notices — the notify
child's stdio is null.

What you get: the tab turns `✓` (and the bell rings) when Codex finishes a
turn, and visiting the window acknowledges it. What you don't get: `working`
and `blocked`, because Codex fires no external event for turn start or approval
prompts. Codex's own approval alert can still reach you in-terminal:

```toml
[tui]
notifications = ["approval-requested"]
```

If Codex ever extends `notify` with more event types, extend the mapping in
the same spirit: parse the JSON argument's `"type"` and pick the word.
