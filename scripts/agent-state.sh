#!/usr/bin/env bash
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
VERSION=0.3.2   # keep in step with .claude-plugin/plugin.json (test/run.sh checks)
state="$1"
[ -n "$AGENT_STATE_LOG" ] && echo "agent-state pane=${TMUX_PANE:-none} $state $2 v=$VERSION self=$0" >> "$AGENT_STATE_LOG"
case "$state" in setup|ack|jump) ;; *) [ -n "$TMUX_PANE" ] || exit 0 ;; esac

TMUX_BIN=$(command -v tmux || command -v /opt/homebrew/bin/tmux || command -v /usr/local/bin/tmux); [ -x "$TMUX_BIN" ] || exit 0   # hooks may run with a minimal PATH
t() { "$TMUX_BIN" "$@" 2>/dev/null; }
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

# ---- render config (runtime only, idempotent) -------------------------------
# Overridable via global options in .tmux.conf:
#   set -g @agent_state_marker    '...'      the tab suffix (default below; must mention @agent_state)
#   set -g @agent_state_processes 'claude|node|bun|codex|gemini|opencode|pi'   what counts as an agent pane
#   set -g @agent_state_tabs      attention  whole tab red when blocked, glyph only otherwise (default)
#                                 colour     whole tab coloured for every state
#                                 marker     glyph only
#   set -g @agent_state_bell      off        never ring the terminal bell (tabs and borders still update)
#   set -g @agent_state_remind    done       what an idle reminder re-rings for: blocked (default), done, or off
#   set -g @agent_state_borders   off        don't colour pane borders by state
#   set -g @agent_state_border_blocked 'fg=#f38ba8'   border styles per state (defaults: fg=red, fg=yellow, fg=green)
#   set -g @agent_state_border_working 'fg=#f9e2af'
#   set -g @agent_state_border_done    'fg=#a6e3a1'
DEFAULT_PROCESSES='claude|node|bun|codex|gemini|opencode|pi'
PANES='#{P:#{@agent_state} }'   # every pane's state in this window, space separated
DEFAULT_MARKER="#{?#{m:*blocked*,$PANES},#[fg=red bold] !,#{?#{m:*working*,$PANES},#[fg=yellow] ~,#{?#{m:*done*,$PANES},#[fg=green] ✓,}}}"
# The 0.2.x marker read a *window* option; strip it on upgrade so tabs keep working without a tmux restart.
OLD_MARKER='#{?#{==:#{@agent_state},blocked},#[fg=red bold] !,}#{?#{==:#{@agent_state},working},#[fg=yellow] ~,}#{?#{==:#{@agent_state},done},#[fg=green] ✓,}'

# ---- reads: three tmux round-trips, not one per option ------------------------
# This runs on every agent event (each tool call), so tmux processes per call are what cost;
# test/run.sh pins the count. A format resolves an option name to its raw value (empty when
# unset), so one display-message reads everything except the two status formats: those are read
# with show -gv because a format would return a window/session-scoped value, or an expanded
# one before the first session exists, and we edit the global option only.
US=$'\037'
read_opts() {
  local o f='' out
  for o in version @agent_state_marker @agent_state_processes @agent_state_processes_active @agent_state_script @agent_state_version \
           @agent_state_tabs @agent_state_tab_prefix @agent_state_bell @agent_state_remind @agent_state_borders @agent_state_borders_supported \
           @agent_state_border_blocked @agent_state_border_working @agent_state_border_done pane_tty @agent_state; do f="$f#{$o}$US"; done
  # shellcheck disable=SC2086  # ${TMUX_PANE:+-t "$TMUX_PANE"} expands to two words on purpose
  out=$(t display -p ${TMUX_PANE:+-t "$TMUX_PANE"} "$f") || return 1
  IFS=$US read -r o_tmux_version o_marker o_procs o_procs_active o_script o_version o_tabs o_tab_prefix o_bell o_remind o_borders o_borders_supported \
    o_border_blocked o_border_working o_border_done o_tty o_state <<< "$out"
  o_wsf=$(t show -gv window-status-format); o_wscf=$(t show -gv window-status-current-format)
}
read_opts || exit 0

ensure_tmux() {
  # Needs tmux >= 3.2 (pane options, regex format match, hook arrays). Older: state is still set, just not drawn.
  local v maj min; v=${o_tmux_version//[!0-9.]/}; maj=${v%%.*}; min=${v#*.}; min=${min%%.*}
  [ "${maj:-0}" -gt 3 ] 2>/dev/null || { [ "${maj:-0}" -eq 3 ] && [ "${min:-0}" -ge 2 ]; } 2>/dev/null || return 0
  local marker procs opt cur rest n idx line
  marker=${o_marker:-$DEFAULT_MARKER}
  procs=${o_procs:-$DEFAULT_PROCESSES}
  case "${procs//|/}" in *[!A-Za-z0-9_-]*) procs=$DEFAULT_PROCESSES ;; esac   # spliced into a regex: process names and | only
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
  local published=$o_script pubver=$o_version
  if [ -z "$published" ] || supersedes "$published" "$pubver"; then
    t set -g @agent_state_script "$SELF"; t set -g @agent_state_version "$VERSION"
  fi
  # Optional: colour the whole tab by state. A style prefix is prepended to the formats; the
  # prefix in use is remembered so a changed or disabled option can remove it cleanly.
  local want_prefix="" had_prefix tabs sb sw sd
  tabs=${o_tabs:-attention}; sb=$o_border_blocked; sw=$o_border_working; sd=$o_border_done
  case "$tabs" in
    colour)    want_prefix="#{?#{m:*blocked*,$PANES},#[${sb:-fg=red} bold],#{?#{m:*working*,$PANES},#[${sw:-fg=yellow}],#{?#{m:*done*,$PANES},#[${sd:-fg=green}],}}}" ;;
    attention) want_prefix="#{?#{m:*blocked*,$PANES},#[${sb:-fg=red} bold],}" ;;
  esac
  had_prefix=$o_tab_prefix
  for opt in window-status-format window-status-current-format; do
    case "$opt" in window-status-format) cur=$o_wsf ;; *) cur=$o_wscf ;; esac; body=${cur//"$OLD_MARKER"/}
    [ -n "$had_prefix" ] && body=${body#"$had_prefix"}
    [ -n "$want_prefix" ] && body=${body#"$want_prefix"}
    rest=${body//"$marker"/}; n=$(( (${#body} - ${#rest}) / ${#marker} ))
    if [ "$n" -gt 1 ]; then body="${rest}${marker}"                       # two first-runs raced; collapse to one
    elif [ "$n" -eq 0 ]; then case "$body" in *@agent_state*) ;; *) body="${body}${marker}" ;; esac   # hand-wired formats are left alone
    fi
    [ "${want_prefix}${body}" = "$cur" ] || t set -g "$opt" "${want_prefix}${body}"
  done
  if [ "$had_prefix" != "$want_prefix" ]; then
    if [ -n "$want_prefix" ]; then t set -g @agent_state_tab_prefix "$want_prefix"; else t set -gu @agent_state_tab_prefix; fi
  fi
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
  [ "$o_procs_active" = "$procs" ] || t set -g @agent_state_processes_active "$procs"   # what ack matches against
  # Per-pane border colours need pane-border-style to be a *pane* option. On older tmux it is
  # a window option and set -p would recolour every pane in the window, so probe once: set it on
  # one pane, see whether the window-level value moved, and put things back.
  if [ -z "$o_borders_supported" ]; then
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
      t set -g @agent_state_borders_supported "$ok"; o_borders_supported=$ok
    fi
  fi
}
case "$state" in ack|jump) ;; *) ensure_tmux ;; esac   # hook- and key-driven modes must never (re)configure
[ "$state" = setup ] && exit 0
if [ "$state" = jump ]; then   # bind in .tmux.conf: bind b run-shell '"$(tmux show -gv @agent_state_script)" jump'
  for want in blocked 'done'; do
    w=$(t list-panes -a -F '#{window_id} #{@agent_state}' | awk -v s="$want" '$2==s{print $1; exit}')
    [ -n "$w" ] && { t switch-client -t "$w" || t select-window -t "$w"; exit 0; }   # switch-client also crosses sessions; no client (tests) falls back
  done
  t display-message 'no agent needs you'; exit 0
fi

# ---- per-pane rendering -----------------------------------------------------
border() {   # border <pane> <state|"">
  [ "$o_borders" = off ] && return 0
  [ "$o_borders_supported" = 1 ] || return 0
  case "$2" in
    blocked) t set -p -t "$1" pane-border-style "${o_border_blocked:-fg=red}" ;;
    working) t set -p -t "$1" pane-border-style "${o_border_working:-fg=yellow}" ;;
    done)    t set -p -t "$1" pane-border-style "${o_border_done:-fg=green}" ;;
    *)       t set -pu -t "$1" pane-border-style ;;
  esac
}
bell() {   # ring this pane's terminal bell: written to its tty so tmux's own bell handling sees it
  [ "$o_bell" = off ] && return 0
  [ -n "$o_tty" ] && [ -w "$o_tty" ] && printf '\a' > "$o_tty" 2>/dev/null; return 0
}

# ---- state ------------------------------------------------------------------
case "$state" in
  ack)   # visiting a window: panes not running an agent lose their state; done -> idle
    procs=${o_procs_active:-$DEFAULT_PROCESSES}
    while read -r pane st cmd; do
      [ -n "$st" ] || continue
      if ! [[ "$cmd" =~ ^($procs)$ ]]; then t set -pu -t "$pane" @agent_state; border "$pane" ""
      elif [ "$st" = 'done' ]; then t set -p -t "$pane" @agent_state idle; border "$pane" ""
      fi
    done <<< "$(t list-panes -t "$2" -F '#{pane_id} #{@agent_state} #{pane_current_command}')" ;;
  clear)  t set -pu -t "$TMUX_PANE" @agent_state; border "$TMUX_PANE" "" ;;
  remind)   # the agent has sat idle a while: re-ring only for states worth a second bell
    case "${o_remind:-blocked}:$o_state" in blocked:blocked|done:blocked|done:done) bell ;; esac ;;
  idle)   t set -p -t "$TMUX_PANE" @agent_state idle; border "$TMUX_PANE" "" ;;
  working|blocked|done)
    t set -p -t "$TMUX_PANE" @agent_state "$state"; border "$TMUX_PANE" "$state"
    case "$state" in blocked|done) bell ;; esac ;;
esac
exit 0
