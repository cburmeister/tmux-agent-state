#!/usr/bin/env bash
# Tests against an isolated tmux server (stock config). Never touches your real tmux.
# Usage: test/run.sh            (add INTEGRATION=1 to also run a real `claude -p` with --plugin-dir)
# Needs: bash, tmux >= 3.2, jq. No agent binaries.
cd "$(dirname "$0")/.." || exit 1
unset TMUX_PANE   # the developer's own pane must not leak into calls that set no pane (setup, jump)
H=$PWD/scripts/agent-state.sh; L=agtest-$$
T() { tmux -L "$L" "$@"; }
cleanup() { T kill-server 2>/dev/null; }; trap cleanup EXIT
fresh() {   # new isolated server: windows 0 | sleeper (not an agent) | agent | duo (two agent panes) | shell
  T kill-server 2>/dev/null; sleep 0.2
  T -f /dev/null new-session -d -s t -x 120 -y 30 'sleep 900' || exit 1
  T new-window -d -n sleeper 'tail -f /dev/null'
  T new-window -d -n agent 'sleep 900'
  T new-window -d -n duo 'sleep 900'; T split-window -d -t t:duo 'sleep 900'
  T new-window -d -n shell
  TMUX="$(T display -p '#{socket_path}'),0,0"; export TMUX
  waitfor sleep T display -p -t t:agent '#{pane_current_command}'   # panes' commands are up (ack matches on them)
  T set -g @agent_state_processes 'claude|sleep'          # the test needs no real agent binary
  T set -g window-status-format '#I:#W'                   # no window flags, so tab assertions are stable
  T set -g @agent_state_tabs marker                       # glyph-only baseline; the tabs modes get their own section
  A=$(T list-panes -t t:agent -F '#{pane_id}'); S=$(T list-panes -t t:sleeper -F '#{pane_id}')
  D1=$(T list-panes -t t:duo -F '#{pane_id}' | head -1); D2=$(T list-panes -t t:duo -F '#{pane_id}' | tail -1)
}
pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL $1: got [$2] want [$3]"; fi; }
st() { T show -pv -t "$1" @agent_state 2>/dev/null; }
bd() { T show -pv -t "$1" pane-border-style 2>/dev/null; }
tab() { T display -p -t "$1" '#{T:window-status-format}'; }
runp() { TMUX_PANE="$1" "$H" "$2"; }
run() { runp "$A" "$1"; }
waitfor() { local want=$1; shift; for _ in $(seq 1 60); do [ "$("$@")" = "$want" ] && return 0; sleep 0.05; done; return 1; }   # poll "$@" until it prints $1 (3s cap)
visit() { T select-window -t "$1"; sleep 0.3; }   # ack runs via run-shell -b, asynchronously; assertions that expect a change also waitfor it
flag() { T display -p -t t:agent '#{window_bell_flag}'; }
unflag() { T select-window -t t:agent; T select-window -t t:0; waitfor 0 flag; }   # visiting clears tmux's bell flag (and acks done -> idle)
count() { T show -gv "$1" | grep -o 'fg=yellow' | wc -l | tr -d ' '; }
hooks() { T show-hooks -g session-window-changed; }

fresh
# --- render config -----------------------------------------------------------
run working; run working; run idle
BS=$(T show -gv @agent_state_borders_supported); echo "pane borders supported on this tmux: $BS"
b() { [ "$BS" = 1 ] && printf '%s' "$1"; }     # expected border value, empty where per-pane borders are unsupported
chk borders-probe-restored "$(T show -wv -t t:agent pane-border-style)" ""
chk marker-appended-once "$(count window-status-format)/$(count window-status-current-format)" "1/1"
chk original-format-kept "$(T show -gv window-status-format | cut -c1-5)" "#I:#W"
chk hook-added-once "$(hooks | grep -c 'agent-state.sh')" "1"
chk script-path-published "$(T show -gv @agent_state_script)" "$H"
T set -g window-status-format '#I:#W'; run idle;              chk self-heal-after-reload "$(count window-status-format)" "1"
M=$(T show -gv window-status-format); M=${M#'#I:#W'}
T set -g window-status-format "#I:#W${M}${M}"; run idle;      chk duplicate-marker-collapsed "$(count window-status-format)" "1"
# upgrade from 0.2.x: window-level marker and format-based hook get replaced, no tmux restart
OLD='#{?#{==:#{@agent_state},blocked},#[fg=red bold] !,}#{?#{==:#{@agent_state},working},#[fg=yellow] ~,}#{?#{==:#{@agent_state},done},#[fg=green] ✓,}'
T set -g window-status-format "#I:#W${OLD}"
T set-hook -ag session-window-changed "if -F '#{==:#{@agent_state},done}' 'set -w @agent_state idle'"
run idle
chk migrate-old-marker-gone "$(T show -gv window-status-format | grep -c '#{==:#{@agent_state},blocked}')" "0"
chk migrate-new-marker-once "$(count window-status-format)" "1"
chk migrate-old-hook-gone "$(hooks | grep -c '#{==:#{@agent_state},done}')/$(hooks | grep -c 'agent-state.sh')" "0/1"

# --- single agent pane -------------------------------------------------------
run working; chk working "$(st "$A")" working; chk working-tab "$(tab t:agent)" "2:agent#[fg=yellow] ~"; chk working-border "$(bd "$A")" "$(b fg=yellow)"
run blocked; chk blocked "$(st "$A")" blocked; chk blocked-tab "$(tab t:agent)" "2:agent#[fg=red bold] !"; chk blocked-border "$(bd "$A")" "$(b fg=red)"
run working; chk unblock "$(st "$A")" working
run 'done';  chk done-state "$(st "$A")" 'done'; chk done-tab "$(tab t:agent)" "2:agent#[fg=green] ✓"; chk done-border "$(bd "$A")" "$(b fg=green)"
waitfor 1 flag; chk bell-flag "$(flag)" 1   # the bell is written to the pane's tty; tmux flags it asynchronously
run idle;    chk idle "$(st "$A")" idle; chk idle-tab "$(tab t:agent)" "2:agent"; chk idle-border-cleared "$(bd "$A")" ""
run remind;  chk remind-noop "$(st "$A")" idle
run 'done'; run remind; chk remind-keeps-done "$(st "$A")" 'done'
# --- bell and remind ---------------------------------------------------------
# The flag is binary, so to see whether remind rings, the state is set with the bell off first.
silently() { T set -g @agent_state_bell off; unflag; run "$1"; T set -gu @agent_state_bell; }
unflag; run blocked; waitfor 1 flag;                    chk bell-blocked "$(flag)" 1
T set -g @agent_state_bell off; unflag; run 'done'; sleep 0.2; chk bell-off "$(flag)" 0; T set -gu @agent_state_bell
silently 'done'; run remind; sleep 0.2;                  chk remind-default-skips-done "$(flag)" 0   # a finished agent is already green
silently blocked; run remind; waitfor 1 flag;            chk remind-rings-for-blocked "$(flag)" 1
T set -g @agent_state_remind 'done'
silently 'done'; run remind; waitfor 1 flag;             chk remind-done-option-rings-for-done "$(flag)" 1
silently blocked; run remind; waitfor 1 flag;            chk remind-done-option-rings-for-blocked "$(flag)" 1
T set -g @agent_state_remind off
silently blocked; run remind; sleep 0.2;                 chk remind-off "$(flag)" 0
T set -gu @agent_state_remind; run idle; unflag

# --- two agents in one window: tab shows the worst pane ---------------------
runp "$D1" blocked; runp "$D2" 'done'; chk duo-blocked+done "$(tab t:duo)" "3:duo#[fg=red bold] !"
runp "$D1" working;                    chk duo-working+done "$(tab t:duo)" "3:duo#[fg=yellow] ~"
runp "$D1" idle;                       chk duo-idle+done "$(tab t:duo)" "3:duo#[fg=green] ✓"
runp "$D2" idle;                       chk duo-idle+idle "$(tab t:duo)" "3:duo"
runp "$D1" blocked; runp "$D2" 'done';  chk duo-borders "$(bd "$D1")/$(bd "$D2")" "$(b fg=red)/$(b fg=green)"

# --- ack on visit: per pane --------------------------------------------------
runp "$D1" working; runp "$D2" 'done'; visit t:0; visit t:duo; waitfor idle st "$D2"
chk ack-keeps-working-pane "$(st "$D1")/$(bd "$D1")" "working/$(b fg=yellow)"
chk ack-done-pane-to-idle "$(st "$D2")/$(bd "$D2")" "idle/"
visit t:agent; visit t:0; run 'done'; T last-window; waitfor idle st "$A";  chk ack-last "$(st "$A")" idle
run 'done'; visit t:sleeper; T next-window; waitfor idle st "$A";           chk ack-next "$(st "$A")" idle
run 'done'; visit t:duo; T previous-window; waitfor idle st "$A";           chk ack-prev "$(st "$A")" idle
run blocked; visit t:0; visit t:agent;                           chk ack-keeps-blocked "$(st "$A")" blocked
T set -p -t "$S" @agent_state 'done'; visit t:sleeper; waitfor "" st "$S"
chk stale-non-agent-cleared "$(st "$S")" ""
run clear; chk clear "$(st "$A")/$(bd "$A")" "/"

# --- jump: blocked first, then done, else stay put --------------------------
run clear; runp "$D1" clear; runp "$D2" clear
runp "$D2" 'done'; run blocked; visit t:0; "$H" jump; chk jump-prefers-blocked "$(T display -p '#W')" agent
run clear; visit t:0; "$H" jump;                     chk jump-falls-back-to-done "$(T display -p '#W')" duo
runp "$D2" clear; visit t:0; "$H" jump;              chk jump-stays-when-nothing "$(T display -p '#I')" 0
# a blocked pane in another session: the attached client (control mode here) is switched there
T new-session -d -s other 'sleep 900'; O=$(T list-panes -t other -F '#{pane_id}')
(sleep 30 | T -C attach -t t >/dev/null 2>&1) & CLIENT=$!; waitfor t T list-clients -F '#{client_session}'
runp "$O" blocked; "$H" jump;                        chk jump-crosses-sessions "$(T list-clients -F '#{client_session}')" other
T switch-client -t t:0; runp "$O" clear; kill $CLIENT 2>/dev/null; T detach-client -a 2>/dev/null; T kill-session -t other

# --- options -----------------------------------------------------------------
T set -g @agent_state_borders off; run blocked; chk borders-off "$(st "$A")/$(bd "$A")" "blocked/"; T set -gu @agent_state_borders; run clear
T set -g @agent_state_border_blocked 'fg=#f38ba8,bold'; run blocked; chk border-style-option "$(bd "$A")" "$(b 'fg=#f38ba8,bold')"; T set -gu @agent_state_border_blocked; run clear
T set -g @agent_state_marker ' X'; T set -g window-status-format '#I:#W'; run working; run working
chk custom-marker-once "$(T show -gv window-status-format)" "#I:#W X"; T set -gu @agent_state_marker; run clear

# --- @agent_state_tabs: attention (default) colours the whole tab for blocked only ---
T set -g window-status-format '#I:#W'; T set -gu @agent_state_tabs; run working; run working
chk tabs-attention-working-plain "$(tab t:agent)" "2:agent#[fg=yellow] ~"
run blocked; chk tabs-attention-blocked-red "$(tab t:agent)" "#[fg=red bold]2:agent#[fg=red bold] !"
run 'done'; chk tabs-attention-done-plain "$(tab t:agent)" "2:agent#[fg=green] ✓"
T set -g @agent_state_tabs marker; run working; chk tabs-marker-plain "$(tab t:agent)" "2:agent#[fg=yellow] ~"
# --- @agent_state_tabs colour: whole tab takes the state colour --------------
T set -g window-status-format '#I:#W'; T set -g @agent_state_tabs colour; run working; run working
chk tabs-colour-prefixed-once "$(T show -gv window-status-format | grep -o 'm:\*blocked\*' | wc -l | tr -d ' ')" "2"
chk tabs-colour-renders "$(tab t:agent)" "#[fg=yellow]2:agent#[fg=yellow] ~"
T set -g @agent_state_border_working 'fg=#f9e2af'; run working
chk tabs-colour-restyled "$(tab t:agent | grep -o 'f9e2af' | wc -l | tr -d ' ')" "1"; T set -gu @agent_state_border_working
T set -g @agent_state_tabs marker; run working
chk tabs-colour-removed "$(T show -gv window-status-format | cut -c1-5)/$(T show -gv @agent_state_tab_prefix 2>/dev/null)" "#I:#W/"; T set -gu @agent_state_tabs; run clear

# --- hot path: tmux processes per steady-state event (every tool call pays this) ---------
SHIM=$(mktemp -d); printf '#!/usr/bin/env bash\necho x >> "%s/n"\nexec "%s" "$@"\n' "$SHIM" "$(command -v tmux)" > "$SHIM/tmux"; chmod +x "$SHIM/tmux"
run working; : > "$SHIM/n"; PATH="$SHIM:$PATH" run working; n=$(wc -l < "$SHIM/n" | tr -d ' ')
chk spawns-per-event "$([ "$n" -le 6 ] && echo ok || echo "$n > 6")" ok; rm -rf "$SHIM"

# --- failure paths: exit 0, no output ---------------------------------------
out=$( (unset TMUX_PANE; $H blocked; echo "rc=$?") 2>&1 );                 chk outside-tmux-silent "$out" "rc=0"
out=$( (TMUX_PANE=%9999 $H blocked; echo "rc=$?") 2>&1 );                   chk bogus-pane-silent "$out" "rc=0"
out=$( (TMUX_PANE=%9999 TMUX='' $H 'done'; echo "rc=$?") 2>&1 );            chk no-server-silent "$out" "rc=0"
out=$( (PATH=/usr/bin:/bin TMUX_PANE="$A" $H 'done'; echo "rc=$?") 2>&1 );  chk no-tmux-in-path "$out/$(st "$A")" "rc=0/done"
out=$( (TMUX_PANE="$A" $H bogus; echo "rc=$?") 2>&1 );                      chk bad-arg-noop "$out/$(st "$A")" "rc=0/done"
out=$( ($H ack %9999; echo "rc=$?") 2>&1 );                                 chk ack-bogus-window-silent "$out" "rc=0"

# --- tmux plugin entry point on a bare server -------------------------------
fresh; T set -g window-status-format '#I:#W'
T set -g @agent_state_processes "claude|sleep'; kill-server; '"; ./agent-state.tmux
chk bad-processes-falls-back "$(T show -gv @agent_state_processes_active)" "claude|node|bun|codex|gemini|opencode|pi"
# setup at config-load time, how tpack/TPM run it: a run-shell in the config, before any pane exists
T kill-server 2>/dev/null; sleep 0.2; CONF=$(mktemp); printf 'set -g window-status-format "#I:#W"\nrun-shell "%s/agent-state.tmux"\n' "$PWD" > "$CONF"
(unset TMUX; T -f "$CONF" new-session -d -s t 'sleep 900'); waitfor 1 count window-status-format; rm -f "$CONF"
chk setup-from-config "$(count window-status-format)/$(T show -gv window-status-format | grep -c '^#{?#{m:\*blocked\*.*#I:#W')/$(hooks | grep -c agent-state.sh)/$(T show -gv @agent_state_script)" "1/1/1/$H"
fresh; ./agent-state.tmux
chk tpm-setup-configures "$(hooks | grep -c agent-state.sh)/$(count window-status-format)/$(T show -gv @agent_state_script)" "1/1/$H"
T set -p -t "$A" @agent_state working; visit t:agent;  chk custom-process-kept "$(st "$A")" working   # sleep is in the list

# --- a plugin update supersedes the hook it left behind, wherever the copies live -------
chk version-in-step "$(grep -o '^VERSION=[0-9.]*' "$H" | cut -d= -f2)" "$(jq -r .version .claude-plugin/plugin.json)"
# the Claude Code adapter's event -> word contract, as documented in README.md and adapters/README.md
chk hooks-contract "$(jq -r '.hooks | to_entries[] | .key as $e | .value[] | (.matcher // "*") as $m | .hooks[].command | sub(".*agent-state.sh ";"") | "\($e):\($m)=\(.)"' hooks/hooks.json | tr '\n' ' ')" \
  "SessionStart:startup|resume|clear=idle UserPromptSubmit:*=working PreToolUse:AskUserQuestion=blocked PostToolUse:*=working PermissionRequest:*=blocked Notification:permission_prompt|elicitation_dialog|agent_needs_input=blocked Notification:idle_prompt=remind Stop:*=done StopFailure:*=blocked SessionEnd:*=clear "
fresh; V=$(mktemp -d); mkdir -p "$V/old/scripts" "$V/new/scripts"
sed 's/^VERSION=.*/VERSION=0.0.1/' "$H" > "$V/old/scripts/agent-state.sh"; sed 's/^VERSION=.*/VERSION=0.0.2/' "$H" > "$V/new/scripts/agent-state.sh"; chmod +x "$V"/*/scripts/agent-state.sh
TMUX_PANE="$A" "$V/old/scripts/agent-state.sh" idle
chk old-version-installs "$(hooks | grep -c '/old/')/$(T show -gv @agent_state_version)" "1/0.0.1"
TMUX_PANE="$A" "$V/new/scripts/agent-state.sh" idle
chk newer-version-supersedes "$(hooks | grep -c '/old/')/$(hooks | grep -c '/new/')/$(T show -gv @agent_state_version)" "0/1/0.0.2"
TMUX_PANE="$A" "$V/old/scripts/agent-state.sh" idle
chk older-version-does-not "$(hooks | grep -c '/new/')/$(T show -gv @agent_state_version)" "1/0.0.2"
./agent-state.tmux
chk setup-always-supersedes "$(hooks | grep -c agent-state.sh)/$(T show -gv @agent_state_script)" "1/$H"
TMUX_PANE="$A" "$V/new/scripts/agent-state.sh" idle
chk bundled-never-supersedes-setup "$(hooks | grep -c '/new/')/$(T show -gv @agent_state_script)" "0/$H"
rm -rf "$V"

if [ -n "$INTEGRATION" ]; then
  log=$(mktemp); out=$(mktemp)
  T send-keys -t t:shell "AGENT_STATE_LOG=$log claude --plugin-dir $PWD -p 'Reply with exactly: ok' >$out 2>&1; echo DONE >>$out" Enter
  for _ in $(seq 1 120); do grep -q DONE "$out" 2>/dev/null && break; sleep 1; done
  chk integration-hooks "$(awk '$3!="ack"{print $3}' "$log" | tr '\n' ' ')" "idle working done clear "
  chk integration-cleared "$(T list-panes -t t:shell -F '#{@agent_state}')" ""
  rm -f "$log" "$out"
fi
echo "pass=$pass fail=$fail"; [ $fail -eq 0 ]
