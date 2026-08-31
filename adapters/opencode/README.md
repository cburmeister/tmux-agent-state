# OpenCode adapter

OpenCode loads JavaScript plugins from `~/.config/opencode/plugins/` (global)
or `.opencode/plugins/` (per project) — see
[opencode.ai/docs/plugins](https://opencode.ai/docs/plugins/). The adapter is
one dependency-free file:

```bash
mkdir -p ~/.config/opencode/plugins
curl -fsSL https://raw.githubusercontent.com/cburmeister/tmux-agent-state/main/adapters/opencode/tmux-agent-state.js \
  -o ~/.config/opencode/plugins/tmux-agent-state.js
```

(or copy it from a clone). Restart OpenCode. The mapping:

| OpenCode event | Word |
|---|---|
| `session.created` | `idle` |
| `message.updated` (role `user`) | `working` |
| `tool.execute.after` | `working` |
| `permission.asked` | `blocked` |
| `permission.replied` | `working` |
| `session.error` | `blocked` |
| `session.idle` | `done` |
| `session.deleted` | `clear` |

It resolves the script through `tmux show -gv @agent_state_script`, published
by the tmux plugin (step 1 in the top-level README), and no-ops outside tmux.
