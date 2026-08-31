# Qwen Code adapter

Qwen Code has a hooks system in `settings.json`
([docs](https://github.com/QwenLM/qwen-code/blob/main/docs/users/features/hooks.md)),
shaped like Claude Code's. The mapping:

| Qwen Code event | Word |
|---|---|
| `SessionStart` | `idle` |
| `UserPromptSubmit`, `PostToolUse`, `PostToolUseFailure` | `working` |
| `PermissionRequest` | `blocked` |
| `PermissionDenied` | `working` |
| `Stop` | `done` |
| `SessionEnd` | `clear` |

Merge [`settings-hooks.json`](settings-hooks.json) into `~/.qwen/settings.json`
(or a project's `.qwen/settings.json`). If you already have a `hooks` object,
add these entries to it.

The commands resolve the script through `tmux show -gv @agent_state_script`,
published by the tmux plugin (step 1 in the top-level README). The script
prints nothing and always exits 0, so a broken indicator can never block the
agent.
