// tmux-agent-state adapter for pi (https://pi.dev).
//
// Install: pi install git:github.com/cburmeister/tmux-agent-state
// (the repo root package.json points pi at this file), or copy this file into
// ~/.pi/agent/extensions/. Requires the tmux plugin from the top-level README.
//
// pi asks for approval only in its non-default confirmation modes and exposes
// no external event for it, so there is no `blocked` here: pi panes go
// working -> done.
//
// Typed loosely on purpose: `import type` would also work under jiti, but this
// way the adapter needs nothing installed, ever.
export default function (pi: any) {
  const report = async (word: string) => {
    if (!process.env.TMUX) return;
    try {
      const found = await pi.exec("tmux", ["show", "-gv", "@agent_state_script"], { timeout: 3000 });
      const script = (found.stdout || "").trim();
      if (found.code === 0 && script) await pi.exec(script, [word], { timeout: 3000 });
    } catch {
      // a broken indicator must never block the agent
    }
  };
  pi.on("session_start", () => report("idle"));
  pi.on("agent_start", () => report("working"));
  pi.on("agent_settled", () => report("done"));   // not agent_end: pi may auto-continue after that
  pi.on("session_shutdown", () => report("clear"));
}
