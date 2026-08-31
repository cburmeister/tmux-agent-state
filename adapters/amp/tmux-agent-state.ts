// tmux-agent-state adapter for Amp (https://ampcode.com).
//
// Install: copy this file into ~/.config/amp/plugins/ (all projects) or
// .amp/plugins/ (one project). Requires the tmux plugin from the top-level
// README, which publishes the script's location as @agent_state_script.
//
// Amp fires no external event for its approval prompts, so there is no
// `blocked` here, and none for session end, so no `clear`: visiting the
// window cleans up when Amp exits. Typed loosely on purpose so the adapter
// needs nothing installed, ever.
export default function (amp: any) {
  const report = async ($: any, word: string) => {
    if (!process.env.TMUX) return;
    try {
      await $`sh -c ${'exec "$(tmux show -gv @agent_state_script)" ' + word}`;
    } catch {
      // a broken indicator must never block the agent
    }
  };
  amp.on("session.start", (_e: any, ctx: any) => report(ctx?.$ ?? amp.$, "idle"));
  amp.on("agent.start", (_e: any, ctx: any) => report(ctx?.$ ?? amp.$, "working"));
  amp.on("tool.result", (_e: any, ctx: any) => report(ctx?.$ ?? amp.$, "working"));
  amp.on("agent.end", (_e: any, ctx: any) => report(ctx?.$ ?? amp.$, "done"));
}
