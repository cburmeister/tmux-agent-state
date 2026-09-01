# Changelog

All notable changes to this project. The version lives in three places that
`test/run.sh` keeps in step: `scripts/agent-state.sh`,
`.claude-plugin/plugin.json`, and `package.json`.

## Unreleased

- README demo gif, recorded by `demo/record.sh` against an isolated tmux
  server (asciinema + agg, cropped to the status bar with gifsicle). The
  three agents are real Claude Code sessions loaded with this plugin; every
  tab change in it is a real hook firing.
- Docs: the `@agent_state_processes` default in `adapters/README.md` had
  drifted (it was missing `qwen|copilot|goose|amp`); a test now pins the
  documented default in both READMEs to the code.
- Docs: the Testing section names the suite's real dependencies (jq, and
  optionally node).

## 0.7.0 - 2026-08-31

- Adapters for four more agents: Qwen Code, Copilot CLI, goose, and Amp.
- Un-block events: `PermissionDenied` (Claude Code, Qwen Code) and
  `ElicitationResult` map to `working`, so a denied permission no longer
  leaves the tab red until the next tool call.
- The triage key cycles: the pane you are in is skipped, so repeated presses
  walk through everything that needs you, oldest first.

## 0.6.0 - 2026-08-31

- Adapters for Codex CLI, Gemini CLI, OpenCode, and pi. The adapter contract
  and every mapping are documented in `adapters/README.md` and pinned by the
  test suite.
- `pick` (bound to `prefix` + `a` at setup, `@agent_state_key` to change): go
  straight to the agent that most needs you, blocked before done, oldest
  first. `jump` remains as a deprecated alias.
- `@agent_state_notify`: run your own command on a state transition, with
  `$AGENT_STATE`, `$AGENT_STATE_PREV`, `$AGENT_STATE_PANE`, and tmux formats;
  `@agent_state_notify_states` picks which states fire it.
- Glyphs and styles are options, one per state: `@agent_state_glyph_*` and
  `@agent_state_style_*`, used everywhere a state is drawn.
- `doctor`: prints what the plugin knows and exits non-zero when something
  needs fixing.
- `uninstall`: undoes everything in the running server; config files are
  never touched.

## 0.3.2 - 2026-08-29

- Claude Code adapter maps `blocked` on `AskUserQuestion`,
  `PermissionRequest`, and the `agent_needs_input` notification.
- `jump` crosses sessions.
- Options are read in three tmux round-trips instead of one per option; the
  test suite pins the per-event process count.
- Intel Homebrew tmux fallback (`/usr/local/bin/tmux`); `bun` counts as an
  agent process.
- CI matrix: tmux 3.2a, 3.4, and Homebrew tmux on macOS bash 3.2.

## 0.3.1 - 2026-08-29

- `@agent_state_bell` and `@agent_state_remind` options.
- `@agent_state_tabs`: `attention` (default, whole tab red only when
  blocked), `colour`, or `marker`.
- Border styles per state (`@agent_state_border_*`).
- `jump`: select the first blocked window, else the first done one.

## 0.2.x - 2026-08-28

- Initial release: agent state on tmux window tabs, driven by Claude Code's
  lifecycle hooks; per-pane borders; bell on `blocked` and `done`; ack on
  visit. Upgrading from 0.2.x is handled in place: the old window-scoped
  marker and format-based hook are migrated on the first event, no tmux
  restart.
