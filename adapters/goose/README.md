# goose adapter

goose loads hooks from plugin directories
([docs](https://goose-docs.ai/docs/guides/context-engineering/hooks/)). The
adapter is one file:

```bash
mkdir -p ~/.agents/plugins/tmux-agent-state/hooks
curl -fsSL https://raw.githubusercontent.com/cburmeister/tmux-agent-state/main/adapters/goose/hooks.json \
  -o ~/.agents/plugins/tmux-agent-state/hooks/hooks.json
```

(or copy it from a clone). The mapping:

| goose event | Word |
|---|---|
| `SessionStart` | `idle` |
| `UserPromptSubmit`, `PostToolUse`, `PostToolUseFailure` | `working` |
| `Stop` | `done` |
| `SessionEnd` | `clear` |

goose fires no event for its approval prompts, so there is no `blocked`
mapping. The commands resolve the script through
`tmux show -gv @agent_state_script`, published by the tmux plugin (step 1 in
the top-level README).
