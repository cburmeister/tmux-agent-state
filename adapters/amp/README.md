# Amp adapter

Amp plugins are TypeScript files run on Bun
([plugin API](https://ampcode.com/docs/plugin-api)); this one is
dependency-free. Install:

```bash
mkdir -p ~/.config/amp/plugins
curl -fsSL https://raw.githubusercontent.com/cburmeister/tmux-agent-state/main/adapters/amp/tmux-agent-state.ts \
  -o ~/.config/amp/plugins/tmux-agent-state.ts
```

(or copy it from a clone; `.amp/plugins/` works per project). The mapping:

| Amp event | Word |
|---|---|
| `session.start` | `idle` |
| `agent.start`, `tool.result` | `working` |
| `agent.end` | `done` |

Amp fires no external event for its approval prompts, so there is no
`blocked` mapping, and none for session end, so no `clear`: visiting the
window cleans the pane up when Amp exits. The plugin resolves the script
through `tmux show -gv @agent_state_script`, published by the tmux plugin
(step 1 in the top-level README), and no-ops outside tmux.
