# Contributing

The contribution this project wants most is an adapter for an agent it does
not cover yet.

## An adapter

An adapter maps an agent's lifecycle events onto six words and calls one
script. [adapters/README.md](adapters/README.md) defines the contract and
lists every current mapping. To add one:

1. Create `adapters/<agent>/` with the agent's native config (a hooks file,
   an extension, a plugin) and a README with the install command.
2. Use the agent's own lifecycle events. Do not read the screen. Do not poll.
3. Add no dependencies. The core is bash and tmux; an adapter may use only
   what the agent itself already runs on.
4. Pin the mapping in `test/run.sh`, next to the other `*-adapter-*` checks.
   If the install snippet can run for real against the isolated test server,
   run it for real.
5. Add the agent to the install section of the top-level README, in the same
   shape as the other entries, and to the mapping table in
   [adapters/README.md](adapters/README.md).
6. If the agent's process name is not in the `@agent_state_processes`
   default, add it there too: `scripts/agent-state.sh`, the README, and the
   test that pins the default.

An agent without usable lifecycle events (Cursor CLI today) gets an honest
line in the README instead of a screen-scraping adapter.

## Everything else

Bug fixes and hardening are welcome. Keep the invariants:

- The script always exits 0 and prints nothing. `doctor` is the one
  exception.
- The steady-state path stays at a handful of tmux calls per event. The test
  suite pins the count.
- shellcheck passes on every shell file.
- `test/run.sh` ends with `fail=0`. CI runs it on tmux 3.2a, 3.4, and
  Homebrew tmux with macOS bash 3.2.

The README gif is recorded by `demo/record.sh` (needs asciinema >= 3, agg,
gifsicle, and a logged-in `claude`), against an isolated tmux server like
the tests. It is cropped to the status bar: the tabs are the whole demo.
The agents in it are real Claude Code sessions, so a run costs three short
turns of API usage. Re-record it when the tab rendering or the triage flow
changes.

For a bug report, include your tmux version and the output of:

```bash
"$(tmux show -gv @agent_state_script)" doctor
```

## Releasing

1. Bump the version in its three homes: `VERSION=` in
   `scripts/agent-state.sh`, `.claude-plugin/plugin.json`, and
   `package.json`. `test/run.sh` fails if they disagree.
2. Add the release to `CHANGELOG.md`.
3. Run `test/run.sh` and shellcheck; commit.
4. Tag it and push the tag: `git tag -a v<version> -m v<version> && git push
   --tags`. Running servers pick the new version up on their next agent
   event (the superseding logic keys on the version), so nothing else ships.
