#!/bin/bash
# tmux-agent-state: agent state on tmux window tabs, driven by the agent's own lifecycle events.
#
# Usage (called by an adapter, e.g. hooks/hooks.json for Claude Code; one argument):
#   working | blocked | done | idle   set this pane's state
#   remind                            re-ring the bell if still blocked/done
#   clear                             remove the state (session ended)
#   setup                             configure tmux only (used by the tmux plugin entry point)
#   jump                              select the first window with a blocked pane, else a done one
#   ack <window_id>                   internal: run by the tmux hook when the current window changes
#
# This script is the whole interface between tmux and any agent. Adapters for
# other agents (Codex, OpenCode, Pi, ...) just call it with one of the words
# above. See adapters/README.md.
#
# State lives in a tmux *pane* option, @agent_state. The window tab shows the
# worst state across its panes (blocked > working > done); each agent pane's
# border is coloured by its own state. On every run the script makes sure the
# running tmux server renders this: it appends a marker to the existing
# window-status formats and adds an ack hook. Nothing on disk is touched; the
# check is content-based so it is idempotent and self-heals after a config
# reload. blocked/done also ring the pane's bell (terminal notification).
#
# Only meaningful inside tmux. Always exits 0 and prints nothing, so a broken
# indicator can never block an agent.
VERSION=0.2.1   # keep in step with .claude-plugin/plugin.json (test/run.sh checks)
state="$1"
[ -n "$AGENT_STATE_LOG" ] && echo "agent-state pane=${TMUX_PANE:-none} $state $2 v=$VERSION self=$0" >> "$AGENT_STATE_LOG"
case "$state" in setup|ack|jump) ;; *) [ -n "$TMUX_PANE" ] || exit 0 ;; esac

TMUX_BIN=$(command -v tmux || echo /opt/homebrew/bin/tmux); [ -x "$TMUX_BIN" ] || exit 0
t() { "$TMUX_BIN" "$@" 2>/dev/null; }
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

# ---- render config (runtime only, idempotent) -------------------------------
# Overridable via global options in .tmux.conf:
#   set -g @agent_state_marker    '...'      the tab suffix (default below; must mention @agent_state)
#   set -g @agent_state_processes 'claude|node|codex|gemini|opencode|pi'   what counts as an agent pane
#   set -g @agent_state_borders   off        don't colour pane borders by state
#   set -g @agent_state_border_blocked 'fg=#f38ba8'   border styles per state (defaults: fg=red, fg=yellow, fg=green)
#   set -g @agent_state_border_working 'fg=#f9e2af'
#   set -g @agent_state_border_done    'fg=#a6e3a1'
DEFAULT_PROCESSES='claude|node|codex|gemini|opencode|pi'
PANES='#{P:#{@agent_state} }'   # every pane's state in this window, space separated
DEFAULT_MARKER="#{?#{m:*blocked*,$PANES},#[fg=red bold] !,#{?#{m:*working*,$PANES},#[fg=yellow] ~,#{?#{m:*done*,$PANES},#[fg=green] ✓,}}}"
# The 0.2.x marker read a *window* option; strip it on upgrade so tabs keep working without a tmux restart.
OLD_MARKER='#{?#{==:#{@agent_state},blocked},#[fg=red bold] !,}#{?#{==:#{@agent_state},working},#[fg=yellow] ~,}#{?#{==:#{@agent_state},done},#[fg=green] ✓,}'

ensure_tmux() {
  # Needs tmux >= 3.2 (pane options, regex format match, hook arrays). Older: state is still set, just not drawn.
  local v maj min; v=$(t -V | sed 's/[^0-9.]//g'); maj=${v%%.*}; min=${v#*.}; min=${min%%.*}
  [ "${maj:-0}" -gt 3 ] 2>/dev/null || { [ "${maj:-0}" -eq 3 ] && [ "${min:-0}" -ge 2 ]; } 2>/dev/null || return 0
  local marker procs opt cur rest n idx line
  marker=$(t show -gv @agent_state_marker); marker=${marker:-$DEFAULT_MARKER}
  procs=$(t show -gv @agent_state_processes); procs=${procs:-$DEFAULT_PROCESSES}
  case "${procs//|/}" in *[!A-Za-z0-9_.-]*) procs=$DEFAULT_PROCESSES ;; esac   # spliced into commands: process names and | only
  # Publish our location and version for adapters. The tmux plugin's copy (setup) is
  # canonical. Any other copy (bundled inside an adapter) takes over only if nothing is
  # published, the published path is gone, or it is a newer version, so a plugin update
  # takes effect without a tmux restart, wherever the agent keeps its copy.
  supersedes() {   # supersedes <path> <version>: should this copy replace what's published?
    [ "$1" != "$SELF" ] || return 1
    [ "$state" = setup ] && return 0
    [ -x "$1" ] || return 0
    [ "$(printf '%s\n%s\n' "$2" "$VERSION" | sort -V | tail -1)" = "$VERSION" ] && [ "$2" != "$VERSION" ]
  }
  local published pubver; published=$(t show -gv @agent_state_script); pubver=$(t show -gv @agent_state_version)
  if [ -z "$published" ] || supersedes "$published" "$pubver"; then
    t set -g @agent_state_script "$SELF"; t set -g @agent_state_version "$VERSION"
  fi
  for opt in window-status-format window-status-current-format; do
    cur=$(t show -gv "$opt"); cur=${cur//"$OLD_MARKER"/}
    rest=${cur//"$marker"/}; n=$(( (${#cur} - ${#rest}) / ${#marker} ))
    if [ "$n" -gt 1 ]; then t set -g "$opt" "${rest}${marker}"          # two first-runs raced; collapse to one
    elif [ "$n" -eq 0 ]; then case "$cur" in *@agent_state*) ;; *) t set -g "$opt" "${cur}${marker}" ;; esac   # hand-wired formats are left alone
    elif [ "$cur" != "$(t show -gv "$opt")" ]; then t set -g "$opt" "$cur"   # only the old marker was removed
    fi
  done
  # Window-change hook: ack the new window's panes. Remove a 0.2.x format-based hook and any
  # duplicate of ours (highest index first, so earlier indices stay valid), then add ours once.
  local seen=0 hpath
  while IFS= read -r line; do
    idx=${line%%]*}; idx=${idx##*[}
    case "$line" in
      *'#{P:#{?#{m/r:'*|*'#{==:#{@agent_state},done}'*) t set-hook -gu "session-window-changed[$idx]" ;;
      *agent-state.sh*ack*)
        hpath=${line#*run-shell -b \"\'}; hpath=${hpath%%\'*}
        if supersedes "$hpath" "$pubver" || [ "$seen" -ge 1 ]; then t set-hook -gu "session-window-changed[$idx]"; else seen=$((seen+1)); fi ;;
    esac
  done <<< "$(t show-hooks -g session-window-changed | sort -t'[' -k2 -rn)"
  [ "$seen" -ge 1 ] || t set-hook -ag session-window-changed "run-shell -b \"'$SELF' ack '#{window_id}'\""
  t set -g @agent_state_processes_active "$procs"   # what ack matches against
  # Per-pane border colours need pane-border-style to be a *pane* option. On older tmux it is
  # a window option and set -p would recolour every pane in the window, so probe once: set it on
  # one pane, see whether the window-level value moved, and put things back.
  if [ -z "$(t show -gv @agent_state_borders_supported)" ]; then
    local probe before after ok=0
    probe=${TMUX_PANE:-$(t list-panes -a -F '#{pane_id}' | head -1)}
    if [ -n "$probe" ]; then
      before=$(t show -wv -t "$probe" pane-border-style)
      t set -p -t "$probe" pane-border-style 'fg=colour8'
      after=$(t show -wv -t "$probe" pane-border-style)
      if [ "$after" = "$before" ]; then ok=1; t set -pu -t "$probe" pane-border-style
      elif [ -n "$before" ]; then t set -w -t "$probe" pane-border-style "$before"
      else t set -wu -t "$probe" pane-border-style
      fi
      t set -g @agent_state_borders_supported "$ok"
    fi
  fi
}
case "$state" in ack|jump) ;; *) ensure_tmux ;; esac   # hook- and key-driven modes must never (re)configure
[ "$state" = setup ] && exit 0
if [ "$state" = jump ]; then   # bind in .tmux.conf: bind b run-shell '"$(tmux show -gv @agent_state_script)" jump'
  for want in blocked 'done'; do
    w=$(t list-panes -a -F '#{window_id} #{@agent_state}' | awk -v s="$want" '$2==s{print $1; exit}')
    [ -n "$w" ] && { t select-window -t "$w"; exit 0; }
  done
  t display-message 'no agent needs you'; exit 0
fi

# ---- per-pane rendering -----------------------------------------------------
border() {   # border <pane> <state|"">
  [ "$(t show -gv @agent_state_borders)" = off ] && return 0
  [ "$(t show -gv @agent_state_borders_supported)" = 1 ] || return 0
  local style
  case "$2" in
    blocked) style=$(t show -gv @agent_state_border_blocked); t set -p -t "$1" pane-border-style "${style:-fg=red}" ;;
    working) style=$(t show -gv @agent_state_border_working); t set -p -t "$1" pane-border-style "${style:-fg=yellow}" ;;
    done)    style=$(t show -gv @agent_state_border_done);    t set -p -t "$1" pane-border-style "${style:-fg=green}" ;;
    *)       t set -pu -t "$1" pane-border-style ;;
  esac
}
bell() {
  local tty; tty=$(t display-message -p -t "$TMUX_PANE" '#{pane_tty}') || return 0
  [ -n "$tty" ] && [ -w "$tty" ] && printf '\a' > "$tty" 2>/dev/null; return 0
}

# ---- state ------------------------------------------------------------------
case "$state" in
  ack)   # visiting a window: panes not running an agent lose their state; done -> idle
    procs=$(t show -gv @agent_state_processes_active); procs=${procs:-$DEFAULT_PROCESSES}
    while read -r pane st cmd; do
      [ -n "$st" ] || continue
      if ! [[ "$cmd" =~ ^($procs)$ ]]; then t set -pu -t "$pane" @agent_state; border "$pane" ""
      elif [ "$st" = 'done' ]; then t set -p -t "$pane" @agent_state idle; border "$pane" ""
      fi
    done <<< "$(t list-panes -t "$2" -F '#{pane_id} #{@agent_state} #{pane_current_command}')" ;;
  clear)  t set -pu -t "$TMUX_PANE" @agent_state; border "$TMUX_PANE" "" ;;
  remind) case "$(t show -pv -t "$TMUX_PANE" @agent_state)" in blocked|done) bell ;; esac ;;
  idle)   t set -p -t "$TMUX_PANE" @agent_state idle; border "$TMUX_PANE" "" ;;
  working|blocked|done)
    t set -p -t "$TMUX_PANE" @agent_state "$state"; border "$TMUX_PANE" "$state"
    case "$state" in blocked|done) bell ;; esac ;;
esac
exit 0
