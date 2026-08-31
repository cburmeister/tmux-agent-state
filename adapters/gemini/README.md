# Gemini CLI adapter

Gemini CLI has a hooks system in `settings.json`
([reference](https://github.com/google-gemini/gemini-cli/blob/main/docs/hooks/reference.md)),
shaped like Claude Code's. The mapping:

| Gemini event | Word |
|---|---|
| `SessionStart` | `idle` |
| `BeforeAgent` (prompt submitted) | `working` |
| `AfterTool` | `working` |
| `Notification` (e.g. `ToolPermission`) | `blocked` |
| `AfterAgent` (final response) | `done` |
| `SessionEnd` | `clear` |

Merge [`settings-hooks.json`](settings-hooks.json) into `~/.gemini/settings.json`
(or a project's `.gemini/settings.json`). If you already have a `hooks` object,
add these entries to it.

The commands resolve the script through `tmux show -gv @agent_state_script`,
published by the tmux plugin (step 1 in the top-level README), so there is no
path to configure. The script prints nothing on stdout, which Gemini treats as
an advisory hook with no directives, and always exits 0, so a broken indicator
can never block the agent.
