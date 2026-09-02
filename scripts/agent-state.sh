#!/usr/bin/env bash
# tmux-agent-state: agent state on tmux window tabs, driven by the agent's own lifecycle events.
#
# Usage (called by an adapter, e.g. hooks/hooks.json for Claude Code; one argument):
#   working | blocked | done | idle   set this pane's state
#   remind                            re-ring the bell if still blocked/done
#   clear                             remove the state (session ended)
#   setup                             configure tmux only (used by the tmux plugin entry point)
#   pick                              go to the agent that most needs you (blocked, else done; oldest first)
#   doctor                            print a diagnosis of the installation (the one mode that prints)
#   uninstall                         undo everything in the running tmux server (config files untouched)
#   jump                              deprecated alias kept for 0.3.x configs: straight to the first
#                                     blocked pane, else the first done one, no UI
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
VERSION=0.7.0   # keep in step with .claude-plugin/plugin.json (test/run.sh checks)
state="$1"
[ -n "$AGENT_STATE_LOG" ] && echo "agent-state pane=${TMUX_PANE:-none} $state $2 v=$VERSION self=$0" >> "$AGENT_STATE_LOG"
case "$state" in setup|ack|jump|pick|doctor|uninstall|_rows) ;; *) [ -n "$TMUX_PANE" ] || exit 0 ;; esac

TMUX_BIN=$(command -v tmux || command -v /opt/homebrew/bin/tmux || command -v /usr/local/bin/tmux)
[ -x "$TMUX_BIN" ] || { [ "$state" = doctor ] && { echo 'tmux-agent-state doctor: tmux not found in PATH'; exit 1; }; exit 0; }   # hooks may run with a minimal PATH
t() { "$TMUX_BIN" "$@" 2>/dev/null; }
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

# ---- render config (runtime only, idempotent) -------------------------------
# Overridable via global options in .tmux.conf:
#   set -g @agent_state_marker    '...'      the tab suffix (default built below; must mention @agent_state)
#   set -g @agent_state_processes 'claude|node|bun|codex|gemini|opencode|pi|qwen|copilot|goose|amp'   what counts as an agent pane
#   set -g @agent_state_glyph_blocked '!'    the marker glyph per state (defaults: ! ~ ✓)
#   set -g @agent_state_glyph_working '~'
#   set -g @agent_state_glyph_done    '✓'
#   set -g @agent_state_style_blocked 'fg=red'      the state's colour, used for the tab glyph, the
#   set -g @agent_state_style_working 'fg=yellow'   whole-tab styles, and (unless overridden
#   set -g @agent_state_style_done    'fg=green'    below) the pane border
#   set -g @agent_state_tabs      attention  whole tab red when blocked, glyph only otherwise (default)
#                                 colour     whole tab coloured for every state
#                                 marker     glyph only
#   set -g @agent_state_bell      off        never ring the terminal bell (tabs and borders still update)
#   set -g @agent_state_remind    done       what an idle reminder re-rings for: blocked (default), done, or off
#   set -g @agent_state_notify    'cmd'      shell command run when a pane *enters* a notifying state (unset: nothing)
#   set -g @agent_state_notify_states 'blocked'   which states fire it: any of working/blocked/done, or off (default: blocked done)
#   set -g @agent_state_key       b          prefix key bound to pick at setup (default a; off binds nothing)
#   set -g @agent_state_borders   off        don't colour pane borders by state
#   set -g @agent_state_border_blocked 'fg=#f38ba8'   border styles per state (default: the style options above)
#   set -g @agent_state_border_working 'fg=#f9e2af'
#   set -g @agent_state_border_done    'fg=#a6e3a1'
DEFAULT_PROCESSES='claude|node|bun|codex|gemini|opencode|pi|qwen|copilot|goose|amp'
PANES='#{P:#{@agent_state} }'   # every pane's state in this window, space separated
# The 0.2.x marker read a *window* option; strip it on upgrade so tabs keep working without a tmux restart.
OLD_MARKER='#{?#{==:#{@agent_state},blocked},#[fg=red bold] !,}#{?#{==:#{@agent_state},working},#[fg=yellow] ~,}#{?#{==:#{@agent_state},done},#[fg=green] ✓,}'

# ---- reads: three tmux round-trips, not one per option ------------------------
# This runs on every agent event (each tool call), so tmux processes per call are what cost;
# test/run.sh pins the count. A format resolves an option name to its raw value (empty when
# unset), so one display-message reads everything except the two status formats: those are read
# with show -gv because a format would return the scope-resolved value, or an expanded
# one before the first session exists, and we edit the global option only.
US=$'\037'
unus() {   # tmux 3.4 escapes non-printable output, so the separator arrives as a literal
  # backslash sequence; 3.2 and 3.5+ emit the raw byte. Put the byte back either way.
  case "$1" in *"$US"*) printf '%s\n' "$1" ;; *) printf '%s\n' "${1//'\037'/$US}" ;; esac
}
read_opts() {
  local o f='' out
  for o in version @agent_state_marker @agent_state_marker_active @agent_state_processes @agent_state_processes_active @agent_state_script @agent_state_version \
           @agent_state_tabs @agent_state_tab_prefix @agent_state_bell @agent_state_remind @agent_state_borders @agent_state_borders_supported \
           @agent_state_border_blocked @agent_state_border_working @agent_state_border_done pane_tty @agent_state \
           @agent_state_glyph_blocked @agent_state_glyph_working @agent_state_glyph_done \
           @agent_state_style_blocked @agent_state_style_working @agent_state_style_done \
           window-status-format window-status-current-format \
           @agent_state_notify_states @agent_state_notify; do f="$f#{$o}$US"; done
  # shellcheck disable=SC2086  # ${TMUX_PANE:+-t "$TMUX_PANE"} expands to two words on purpose
  out=$(t display -p ${TMUX_PANE:+-t "$TMUX_PANE"} "$f") || return 1
  out=$(unus "$out")
  IFS=$US read -r o_tmux_version o_marker o_marker_active o_procs o_procs_active o_script o_version o_tabs o_tab_prefix o_bell o_remind o_borders o_borders_supported \
    o_border_blocked o_border_working o_border_done o_tty o_state \
    o_glyph_blocked o_glyph_working o_glyph_done o_style_blocked o_style_working o_style_done \
    o_wsf_eff o_wscf_eff \
    o_notify_states o_notify <<< "$out"   # notify last: one read stops at a newline, so a multi-line command truncates only itself
  o_wsf=$(t show -gv window-status-format); o_wscf=$(t show -gv window-status-current-format)   # the format fields above are the *effective* (scope-resolved) values, raw; these are the global ones we edit
}
if ! read_opts; then
  [ "$state" = doctor ] && { echo "tmux-agent-state $VERSION doctor: no tmux server is running (start tmux first)"; exit 1; }
  exit 0
fi

# The per-state look, used everywhere something is drawn. Glyphs and styles are spliced into
# tmux conditional formats, where a comma or brace would change the format's meaning, so a
# style's commas become spaces (both are valid style separators) and a hostile glyph falls back.
style_b=${o_style_blocked:-${o_border_blocked:-fg=red}}; style_b=${style_b//,/ }
style_w=${o_style_working:-${o_border_working:-fg=yellow}}; style_w=${style_w//,/ }
style_d=${o_style_done:-${o_border_done:-fg=green}}; style_d=${style_d//,/ }
glyph() { case "$1" in ''|*[,#{}]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac; }
g_b=$(glyph "$o_glyph_blocked" '!'); g_w=$(glyph "$o_glyph_working" '~'); g_d=$(glyph "$o_glyph_done" '✓')
DEFAULT_MARKER="#{?#{m:*blocked*,$PANES},#[$style_b bold] $g_b,#{?#{m:*working*,$PANES},#[$style_w] $g_w,#{?#{m:*done*,$PANES},#[$style_d] $g_d,}}}"

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
  elif [ "$published" = "$SELF" ] && [ "$pubver" != "$VERSION" ]; then
    t set -g @agent_state_version "$VERSION"   # same copy updated in place (a git pull): refresh
  fi
  # Optional: colour the whole tab by state. A style prefix is prepended to the formats; the
  # prefix and marker in use are remembered so a changed or disabled option is swapped cleanly,
  # without waiting for a tmux restart.
  local want_prefix="" had_prefix had_marker tabs
  tabs=${o_tabs:-attention}
  case "$tabs" in
    colour)    want_prefix="#{?#{m:*blocked*,$PANES},#[$style_b bold],#{?#{m:*working*,$PANES},#[$style_w],#{?#{m:*done*,$PANES},#[$style_d],}}}" ;;
    attention) want_prefix="#{?#{m:*blocked*,$PANES},#[$style_b bold],}" ;;
  esac
  had_prefix=$o_tab_prefix; had_marker=$o_marker_active
  weave() {   # weave <format>: that format carrying exactly one current marker and prefix
    local body=${1//"$OLD_MARKER"/} rest n
    [ -n "$had_prefix" ] && body=${body#"$had_prefix"}
    [ -n "$want_prefix" ] && body=${body#"$want_prefix"}
    [ -n "$had_marker" ] && [ "$had_marker" != "$marker" ] && body=${body//"$had_marker"/}   # glyph/style option changed: swap the old marker out
    rest=${body//"$marker"/}; n=$(( (${#body} - ${#rest}) / ${#marker} ))
    if [ "$n" -gt 1 ]; then body="${rest}${marker}"                       # two first-runs raced; collapse to one
    elif [ "$n" -eq 0 ]; then case "$body" in *@agent_state*) ;; *) body="${body}${marker}" ;; esac   # hand-wired formats are left alone
    fi
    printf '%s%s' "$want_prefix" "$body"
  }
  local new eff
  for opt in window-status-format window-status-current-format; do
    case "$opt" in window-status-format) cur=$o_wsf ;; *) cur=$o_wscf ;; esac
    new=$(weave "$cur")
    [ "$new" = "$cur" ] || t set -g "$opt" "$new"
  done
  # A theme that sets a format at window scope outranks the global copy and hides the
  # marker there (window scope is the only scope beside global: a flagless `set` on a
  # window option lands on the window). The *effective* values ride the batched read, so
  # detection costs nothing; only a window that is actually overridden pays the two extra
  # calls, once, on its own agent's event.
  if [ -n "$TMUX_PANE" ]; then
    local swap
    for opt in window-status-format window-status-current-format; do
      case "$opt" in window-status-format) eff=$o_wsf_eff ;; *) eff=$o_wscf_eff ;; esac
      case "$eff" in ''|*"$marker"*) continue ;; esac
      swap=''   # a stale marker from before a glyph/style change mentions @agent_state too,
      [ -n "$had_marker" ] && [ "$had_marker" != "$marker" ] && case "$eff" in *"$had_marker"*) swap=1 ;; esac
      [ -n "$swap" ] || case "$eff" in *@agent_state*) continue ;; esac   # ... but a hand-wired format is left alone
      cur=$(t show -wv -t "$TMUX_PANE" "$opt"); [ -n "$cur" ] || continue
      new=$(weave "$cur")
      [ "$new" = "$cur" ] || t set -w -t "$TMUX_PANE" "$opt" "$new"
    done
  fi
  if [ "$had_prefix" != "$want_prefix" ]; then
    if [ -n "$want_prefix" ]; then t set -g @agent_state_tab_prefix "$want_prefix"; else t set -gu @agent_state_tab_prefix; fi
  fi
  [ "$had_marker" = "$marker" ] || t set -g @agent_state_marker_active "$marker"
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
case "$state" in ack|jump|pick|doctor|uninstall|_rows) ;; *) ensure_tmux ;; esac   # hook-, key- and user-driven modes must never (re)configure
if [ "$state" = setup ]; then
  # Ship the keybinding rather than only documenting it: every comparable plugin binds a key at
  # install time, and a plugin you have to hand-wire before it does anything is friction, not
  # minimalism. Only here in setup, which runs once at tmux start, so the hot path never pays for it.
  key=$(t show -gv @agent_state_key); key=${key:-a}
  [ "$key" = off ] || t bind-key "$key" run-shell "'$SELF' pick"
  exit 0
fi
if [ "$state" = jump ]; then   # bind in .tmux.conf: bind b run-shell '"$(tmux show -gv @agent_state_script)" jump'
  for want in blocked 'done'; do
    w=$(t list-panes -a -F '#{window_id} #{@agent_state}' | awk -v s="$want" '$2==s{print $1; exit}')
    [ -n "$w" ] && { t switch-client -t "$w" || t select-window -t "$w"; exit 0; }   # switch-client also crosses sessions; no client (tests) falls back
  done
  t display-message 'no agent needs you'; exit 0
fi

# ---- pick: triage every agent pane ------------------------------------------
# UI-only, like jump and ack: never runs ensure_tmux, so a keypress cannot reconfigure anything.
# bind in .tmux.conf: bind a run-shell '"$(tmux show -gv @agent_state_script)" pick'
goto_pane() {   # goto_pane <pane_id>: cross-session safe, lands on the agent pane itself
  local w; w=$(t display -p -t "$1" '#{window_id}'); [ -n "$w" ] || return 0
  t switch-client -t "$w" || t select-window -t "$w"   # switch-client also crosses sessions; no client (tests) falls back
  t select-pane -t "$1"; return 0
}

pick_rows() {   # rank US pane US window US session US windex US wname US state US age -- sorted, filtered
  # One list-panes call. Filtered to panes that have a state AND run an agent process, using the same
  # predicate ack uses, so pick and the tabs can never disagree. blocked > done > working > idle,
  # then longest-waiting first: what needs you, oldest first, then what is ready, then what is busy.
  local procs=${o_procs_active:-$DEFAULT_PROCESSES} now rows; now=$(date +%s)
  rows=$(t list-panes -a -F "#{pane_id}$US#{window_id}$US#{session_name}$US#{window_index}$US#{window_name}$US#{@agent_state}$US#{@agent_state_since}$US#{pane_current_command}")
  unus "$rows" \
  | awk -F"$US" -v OFS="$US" -v procs="^($procs)\$" -v now="$now" '
      $6 != "" && $8 ~ procs {
        rank = ($6=="blocked") ? 1 : ($6=="done") ? 2 : ($6=="working") ? 3 : 4
        age  = ($7 ~ /^[0-9]+$/ && $7+0 > 0) ? now - $7 : -1
        print rank, $1, $2, $3, $4, $5, $6, age
      }' \
  | sort -t"$US" -k1,1n -k8,8nr
}
if [ "$state" = _rows ]; then pick_rows | tr "$US" ' '; exit 0; fi   # internal: test seam for the row logic
if [ "$state" = pick ]; then
  # No UI, ever: go straight to the agent that most needs you. pick_rows already ranks them
  # blocked before done and longest-waiting first. The pane you are already in is skipped,
  # so pressing the key again walks through everything that needs you, oldest first.
  here=$(t display -p '#{pane_id}')
  pane=$(pick_rows | awk -F"$US" -v here="$here" '
    $1 <= 2 { if (first == "") first = $2; if ($2 != here) { print $2; found = 1; exit } }
    END { if (!found && first != "") print first }')
  [ -n "$pane" ] || { t display-message 'no agent needs you'; exit 0; }
  goto_pane "$pane"; exit 0
fi

# ---- doctor: the one mode that prints ---------------------------------------
if [ "$state" = doctor ]; then
  broken=0
  row() { printf '  %-11s %s\n' "$1" "$2"; }
  bad() { printf '  %-11s PROBLEM: %s\n' "$1" "$2"; broken=1; }
  echo "tmux-agent-state $VERSION doctor"
  dv=${o_tmux_version//[!0-9.]/}; dmaj=${dv%%.*}; dmin=${dv#*.}; dmin=${dmin%%.*}
  if [ "${dmaj:-0}" -gt 3 ] 2>/dev/null || { [ "${dmaj:-0}" -eq 3 ] && [ "${dmin:-0}" -ge 2 ]; } 2>/dev/null; then
    row tmux "$o_tmux_version at $TMUX_BIN (>= 3.2, ok)"
  else bad tmux "$o_tmux_version at $TMUX_BIN, needs >= 3.2: state is tracked but nothing is drawn"; fi
  if [ -z "$o_script" ]; then bad script "not published yet: run '$SELF setup', or let any adapter event do it"
  elif [ ! -x "$o_script" ]; then bad script "published copy $o_script is gone: run '$SELF setup' to re-publish"
  else
    dextra=''; [ "$o_script" = "$SELF" ] || dextra=" (you are asking a different copy: $SELF, $VERSION)"
    row script "$o_script (${o_version:-unknown})$dextra"
  fi
  dmarker=${o_marker_active:-${o_marker:-$DEFAULT_MARKER}}; dfound=0
  case "$o_wsf" in *"$dmarker"*|*@agent_state*) dfound=$((dfound+1)) ;; esac
  case "$o_wscf" in *"$dmarker"*|*@agent_state*) dfound=$((dfound+1)) ;; esac
  case "$dfound" in
    2) row tabs "marker present in both window-status formats" ;;
    *) bad tabs "marker missing from the global window-status format(s): any agent event re-adds it" ;;
  esac
  if [ -n "$TMUX" ]; then   # a theme that sets the format at window scope hides the global marker there
    dsv=$(t show -wv window-status-format)
    case "$dsv" in ''|*"$dmarker"*|*@agent_state*) ;; *) bad tabs "this window overrides window-status-format (a theme?): its next agent event weaves the marker in" ;; esac
  fi
  dhooks=$(t show-hooks -g session-window-changed | grep -c 'agent-state.sh.*ack')
  case "$dhooks" in
    1) row 'ack hook' "installed (visiting a window acknowledges it)" ;;
    0) bad 'ack hook' "missing: done panes will never go back to idle; any agent event re-adds it" ;;
    *) bad 'ack hook' "$dhooks copies installed; any agent event collapses them to one" ;;
  esac
  dkeys=$(t list-keys -T prefix 2>/dev/null | grep -E "agent-state\.sh' (pick|jump)" | awk '{printf "prefix %s -> %s\n", $4, $NF}' | tr -d '"' | tr '\n' ',' | sed 's/,$//;s/,/, /g')
  if [ -n "$dkeys" ]; then row keys "$dkeys"; else row keys "none bound (set at tmux start by the plugin entry point; see @agent_state_key)"; fi
  case "$o_borders_supported" in
    1) row borders "per-pane border styles supported" ;;
    0) row borders "per-pane border styles not supported on this tmux (tabs still work)" ;;
    *) row borders "not probed yet (first agent event probes it)" ;;
  esac
  row processes "${o_procs_active:-$DEFAULT_PROCESSES (defaults; no agent event yet)}"
  dprocs=${o_procs_active:-$DEFAULT_PROCESSES}; dn=0; dn_b=0; dn_w=0; dn_d=0; dn_i=0
  while IFS=$US read -r dst dcmd; do
    [ -n "$dst" ] || continue; [[ "$dcmd" =~ ^($dprocs)$ ]] || continue
    dn=$((dn+1))
    case "$dst" in blocked) dn_b=$((dn_b+1)) ;; working) dn_w=$((dn_w+1)) ;; done) dn_d=$((dn_d+1)) ;; idle) dn_i=$((dn_i+1)) ;; esac
  done <<< "$(unus "$(t list-panes -a -F "#{@agent_state}$US#{pane_current_command}")")"
  if [ "$dn" -gt 0 ]; then row agents "$dn pane(s) reporting: $dn_b blocked, $dn_w working, $dn_d done, $dn_i idle"
  else row agents "none reporting yet: start an agent turn in a tmux pane (is its adapter installed?)"; fi
  exit "$broken"
fi

# ---- uninstall: undo everything in the running server ------------------------
if [ "$state" = uninstall ]; then
  umarker=${o_marker:-$DEFAULT_MARKER}
  for opt in window-status-format window-status-current-format; do
    case "$opt" in window-status-format) cur=$o_wsf ;; *) cur=$o_wscf ;; esac
    body=${cur//"$OLD_MARKER"/}; body=${body//"$umarker"/}
    [ -n "$o_marker_active" ] && body=${body//"$o_marker_active"/}
    [ -n "$o_tab_prefix" ] && body=${body//"$o_tab_prefix"/}
    [ "$body" = "$cur" ] || t set -g "$opt" "$body"
  done
  # window-scoped copies woven in over a theme's per-window formats
  for opt in window-status-format window-status-current-format; do
    while IFS= read -r w; do
      [ -n "$w" ] || continue
      cur=$(t show -wv -t "$w" "$opt"); [ -n "$cur" ] || continue
      body=${cur//"$OLD_MARKER"/}; body=${body//"$umarker"/}
      [ -n "$o_marker_active" ] && body=${body//"$o_marker_active"/}
      [ -n "$o_tab_prefix" ] && body=${body//"$o_tab_prefix"/}
      [ "$body" = "$cur" ] || t set -w -t "$w" "$opt" "$body"
    done <<< "$(t list-windows -a -F '#{window_id}')"
  done
  while IFS= read -r line; do
    case "$line" in *agent-state.sh*ack*) idx=${line%%]*}; idx=${idx##*[}; t set-hook -gu "session-window-changed[$idx]" ;; esac
  done <<< "$(t show-hooks -g session-window-changed | sort -t'[' -k2 -rn)"
  while IFS= read -r ukey; do [ -n "$ukey" ] && t unbind-key "$ukey"; done \
    <<< "$(t list-keys -T prefix 2>/dev/null | grep -E "agent-state\.sh' (pick|jump)" | awk '{print $4}')"
  while IFS=$US read -r upane ust; do
    [ -n "$ust" ] || continue
    t set -pu -t "$upane" @agent_state ';' set -pu -t "$upane" @agent_state_since
    t set -pu -t "$upane" pane-border-style
  done <<< "$(unus "$(t list-panes -a -F "#{pane_id}$US#{@agent_state}")")"
  for o in @agent_state_script @agent_state_version @agent_state_processes_active @agent_state_tab_prefix \
           @agent_state_marker_active @agent_state_borders_supported; do t set -gu "$o"; done
  echo 'tmux-agent-state: removed from the running tmux server. Your config files were not touched.'
  exit 0
fi

# ---- per-pane rendering -----------------------------------------------------
border() {   # border <pane> <state|"">
  [ "$o_borders" = off ] && return 0
  [ "$o_borders_supported" = 1 ] || return 0
  case "$2" in
    blocked) t set -p -t "$1" pane-border-style "${o_border_blocked:-$style_b}" ;;
    working) t set -p -t "$1" pane-border-style "${o_border_working:-$style_w}" ;;
    done)    t set -p -t "$1" pane-border-style "${o_border_done:-$style_d}" ;;
    *)       t set -pu -t "$1" pane-border-style ;;
  esac
}
bell() {   # ring this pane's terminal bell: written to its tty so tmux's own bell handling sees it
  [ "$o_bell" = off ] && return 0
  [ -n "$o_tty" ] && [ -w "$o_tty" ] && printf '\a' > "$o_tty" 2>/dev/null; return 0
}
notify() {   # notify <new state>: hand the user's own command a state *transition*
  # Costs nothing when @agent_state_notify is unset: both options ride the batched read, and
  # o_state is the pane's previous state, so working -> working (every tool call) never gets here.
  # run-shell -b backgrounds the command in the tmux server (a notifier that hangs can't delay the
  # agent) and expands formats in it, so #{window_name} and friends work. It does *not* inherit our
  # environment, though, so the vars are prepended as assignments to the sh the server runs the
  # command with -- set *and* exported, so both "$AGENT_STATE" in the command and a child reading
  # the environment see them. A plain assignment prefix would only reach the child.
  [ -n "$o_notify" ] || return 0
  local states=${o_notify_states:-blocked done} prev=${o_state//[!a-z]/} cmd=$o_notify
  [ "$states" = off ] && return 0
  [ "$1" != "$prev" ] || return 0
  case " $states " in *" $1 "*) ;; *) return 0 ;; esac
  # tmux 3.4 (only: introduced there, reverted in 3.5) stores option values with $ escaped
  # as \$, so the command's "$AGENT_STATE" would reach sh as a literal. Undo it there.
  case "$o_tmux_version" in 3.4*) cmd=${cmd//'\$'/$} ;; esac
  t run-shell -b -t "$TMUX_PANE" "AGENT_STATE=$1 AGENT_STATE_PREV=$prev AGENT_STATE_PANE=$TMUX_PANE
export AGENT_STATE AGENT_STATE_PREV AGENT_STATE_PANE
$cmd"
  return 0
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
  clear)  t set -pu -t "$TMUX_PANE" @agent_state ';' set -pu -t "$TMUX_PANE" @agent_state_since; border "$TMUX_PANE" "" ;;
  remind)   # the agent has sat idle a while: re-ring only for states worth a second bell
    case "${o_remind:-blocked}:$o_state" in blocked:blocked|done:blocked|done:done) bell ;; esac ;;
  idle)   t set -p -t "$TMUX_PANE" @agent_state idle; border "$TMUX_PANE" "" ;;
  working|blocked|done)
    # Only on a real transition: steady-state working (every tool call) skips the write and the
    # border entirely, and @agent_state_since rides the same tmux invocation as @agent_state, so
    # the timestamp pick needs costs nothing. The bell stays outside: it has always rung on
    # every blocked/done event, and remind depends on that.
    if [ "$state" != "${o_state//[!a-z]/}" ]; then
      t set -p -t "$TMUX_PANE" @agent_state "$state" ';' set -p -t "$TMUX_PANE" @agent_state_since "$(date +%s)"
      border "$TMUX_PANE" "$state"
    fi
    case "$state" in blocked|done) bell ;; esac
    notify "$state" ;;
esac
exit 0
