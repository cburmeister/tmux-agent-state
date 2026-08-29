#!/usr/bin/env bash
# tmux plugin entry point (tpack / TPM): `set -g @plugin 'cburmeister/tmux-agent-state'` in .tmux.conf.
# Configures the tmux side at startup so any agent adapter can start reporting.
exec "$(cd "$(dirname "$0")" && pwd)/scripts/agent-state.sh" setup
