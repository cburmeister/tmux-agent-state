# pi adapter

[pi](https://pi.dev) extensions are TypeScript modules; this one is
dependency-free. Install it as a pi package straight from this repo:

```bash
pi install git:github.com/cburmeister/tmux-agent-state
```

or copy [`index.ts`](index.ts) into `~/.pi/agent/extensions/`. The mapping:

| pi event | Word |
|---|---|
| `session_start` | `idle` |
| `agent_start` | `working` |
| `agent_settled` | `done` |
| `session_shutdown` | `clear` |

`agent_settled` rather than `agent_end`, because pi may auto-retry, compact,
or continue with queued messages after `agent_end`; `settled` means it will
not continue on its own — that is `done`. pi exposes no external event for its
confirmation prompts, so there is no `blocked` mapping.

The extension resolves the script through `tmux show -gv @agent_state_script`,
published by the tmux plugin (step 1 in the top-level README), and no-ops
outside tmux.
