#!/usr/bin/env bash
# Records the README demo: demo/demo.cast (asciinema) and demo/demo.gif (agg).
# Runs against an isolated tmux server, like the test suite; never touches yours.
#
# The three agents are REAL Claude Code sessions, loaded with this plugin via
# --plugin-dir; every state change in the recording is a real hook firing. The
# timing is therefore polled, not scripted, and asciinema's idle-time limit
# collapses the model's thinking time in playback.
#
# The gif is cropped to the status bar: the tabs are the whole demo.
#
# Needs: bash, tmux >= 3.2, asciinema >= 3, agg, gifsicle, and a logged-in
# `claude` that trusts this directory. Costs three short turns of API usage.
set -euo pipefail
cd "$(dirname "$0")/.."
L=agdemo-$$; CAST=demo/demo.cast; GIF=demo/demo.gif
T() { tmux -L "$L" "$@"; }
cleanup() { T kill-server 2>/dev/null || true; rm -f "$CONF" "${SET:-}" /tmp/agdemo-plan.md; }
trap cleanup EXIT
for c in claude asciinema agg gifsicle; do
  command -v "$c" >/dev/null || { echo "demo: needs $c in PATH" >&2; exit 1; }
done

CONF=$(mktemp)
# A real-life status bar: session name, a separator, plain window tabs with
# the current one in colour, a clock. Nothing invented for the camera.
cat > "$CONF" <<'EOF'
set -g base-index 1
set -g renumber-windows on
set -g status-interval 1
set -g status-justify left
set -g status-style 'bg=default'
set -g status-left "#[fg=#a6e3a1,bold] #S #[fg=#45475a]| "
set -g status-right "#[fg=#f5c2e7] %H:%M "
set -g status-right-length 70
setw -g window-status-style 'fg=#6c7086'
setw -g window-status-format ' #I:#W '
setw -g window-status-current-style 'fg=#89b4fa,bold'
setw -g window-status-current-format ' #I:#W '
set -g window-status-bell-style none   # the plugin's colours are the whole story; no blink on top
set -as terminal-features ',xterm-256color:RGB'
EOF

T -f "$CONF" new-session -d -s demo -x 100 -y 27 -n shell
# --permission-mode default so the web task really prompts, whatever the
# machine's own defaultMode is (that prompt is the whole blocked scene);
# --strict-mcp-config and a bare statusline keep personal config out of frame.
SET=$(mktemp); printf '{"statusLine":{"type":"command","command":"true"}}' > "$SET"
CC="claude --plugin-dir '$PWD' --permission-mode default --strict-mcp-config --settings '$SET'"
T new-window -d -n api  "$CC"
T new-window -d -n web  "$CC"
T new-window -d -n jobs "$CC"
TMUX="$(T display -p '#{socket_path}'),0,0"; export TMUX
./agent-state.tmux   # real setup: marker, hook, key

pane() { T list-panes -t "demo:$1" -F '#{pane_id}'; }
P_API=$(pane api); P_WEB=$(pane web); P_JOBS=$(pane jobs)

st() { T show -pv -t "$1" @agent_state 2>/dev/null; }
waitfor() {   # waitfor <state> <pane> [seconds]: poll the real pane option the hooks set
  local want=$1 p=$2 secs=${3:-180} i
  for ((i = 0; i < secs * 2; i++)); do [ "$(st "$p")" = "$want" ] && return 0; sleep 0.5; done
  echo "demo: pane $p never reached '$want' (state: '$(st "$p")'); is claude logged in and this directory trusted?" >&2
  exit 1
}
ask() { T send-keys -t "$1" -l "$2"; sleep 0.3; T send-keys -t "$1" Enter; }
note() { T set -g status-right "#[fg=#f9e2af]$1 #[fg=#f5c2e7] %H:%M "; }   # narration beside the clock

# The sessions are up once their SessionStart hook has reported idle.
for p in "$P_API" "$P_WEB" "$P_JOBS"; do waitfor idle "$p" 120; done

env -u TMUX TERM=xterm-256color \
  asciinema rec -q --headless --overwrite --window-size 100x28 --idle-time-limit 3 \
  --title 'tmux-agent-state' --command "tmux -L $L attach -t demo" "$CAST" &
REC=$!
for _ in $(seq 1 100); do [ -n "$(T list-clients 2>/dev/null)" ] && break; sleep 0.1; done
sleep 1

# --- scene 1: you in your shell; three real agents get their prompts ----------
ask "$P_JOBS" 'In one sentence: why might a nightly reindex job suddenly OOM after a deploy? No tools, just answer.'
sleep 0.8
ask "$P_WEB" 'Use the Write tool to create /tmp/agdemo-plan.md: a 3-line plan for adding an expires_at column to the sessions table.'
sleep 0.8
ask "$P_API" 'Read scripts/agent-state.sh and describe in one sentence what it does.'
note 'three agents at work: ~'
sleep 2

# --- scene 2: jobs finishes (✓), web gets stuck on a permission (!) -----------
waitfor 'done' "$P_JOBS"
note 'jobs finished: ✓ (the bell rang)'
sleep 2.2
waitfor blocked "$P_WEB"
note 'web needs you: ! — press prefix + a'
sleep 2.6

# --- scene 3: prefix + a goes straight to what needs you ----------------------
scripts/agent-state.sh pick   # exactly what the bound key runs
note 'blocked first, oldest first'
sleep 3                       # the real permission prompt, on screen
T send-keys -t "$P_WEB" Enter # approve it
note ''
sleep 2.5                     # a moment of the real turn resuming

# --- scene 4: next press, next thing; visiting acknowledges -------------------
scripts/agent-state.sh pick   # nothing blocked now: the oldest ✓, which is jobs
sleep 0.6
note 'visiting acknowledges: ✓ clears'
sleep 2.6

# --- scene 5: back home; the rest lands on its own ----------------------------
waitfor 'done' "$P_WEB"
waitfor 'done' "$P_API"
T select-window -t demo:shell
note 'you never left your shell'
sleep 3
T kill-server 2>/dev/null || true
wait "$REC" 2>/dev/null || true

# End the gif on the last scene, not on the client's exit (screen clear,
# "[server exited]"): keep through the last status redraw that carries the
# closing narration, drop everything after.
end=$(grep -n 'never left your shell' "$CAST" | tail -1 | cut -d: -f1)
[ -z "$end" ] && end=$(( $(grep -n '1049l' "$CAST" | head -1 | cut -d: -f1) - 1 ))   # fallback
[ "$end" -gt 0 ] 2>/dev/null && { head -n "$end" "$CAST" > "$CAST.tmp" && mv "$CAST.tmp" "$CAST"; }

agg --theme 1e1e2e,cdd6f4,45475a,f38ba8,a6e3a1,f9e2af,89b4fa,f5c2e7,94e2d5,bac2de,585b70,f38ba8,a6e3a1,f9e2af,89b4fa,f5c2e7,94e2d5,a6adc8 \
    --font-size 16 --idle-time-limit 3 --last-frame-duration 3 "$CAST" "$GIF"

# Crop to the status bar: a 44px bottom strip leaves the bar text measured
# 14px from both edges; -O3 also collapses the frames where nothing on the
# bar changed.
read -r GW GH <<< "$(gifsicle --info "$GIF" | sed -n 's/.*logical screen \([0-9]*\)x\([0-9]*\).*/\1 \2/p')"
gifsicle --crop "0,$((GH - 44))-$GW,$GH" -O3 "$GIF" -o "$GIF.tmp" && mv "$GIF.tmp" "$GIF"
echo "wrote $CAST and $GIF"
