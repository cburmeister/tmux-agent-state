# GitHub Copilot CLI adapter

Copilot CLI loads hook files from `~/.copilot/hooks/*.json`
([reference](https://docs.github.com/en/copilot/reference/hooks-reference)).
The adapter is one file:

```bash
mkdir -p ~/.copilot/hooks
curl -fsSL https://raw.githubusercontent.com/cburmeister/tmux-agent-state/main/adapters/copilot/hooks.json \
  -o ~/.copilot/hooks/tmux-agent-state.json
```

(or copy it from a clone). The mapping:

| Copilot CLI event | Word |
|---|---|
| `sessionStart` | `idle` |
| `userPromptSubmitted`, `postToolUse`, `postToolUseFailure` | `working` |
| `permissionRequest` | `blocked` |
| `agentStop` | `done` |
| `sessionEnd` | `clear` |

The `permissionRequest` hook is a decision hook for Copilot; this one prints
nothing, which Copilot treats as "no opinion", so your normal permission flow
is untouched. The commands resolve the script through
`tmux show -gv @agent_state_script`, published by the tmux plugin (step 1 in
the top-level README).
