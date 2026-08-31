// tmux-agent-state adapter for OpenCode.
//
// Install: copy this one file into ~/.config/opencode/plugins/ (all projects) or
// .opencode/plugins/ (one project). Requires the tmux plugin from the top-level
// README, which publishes the script's location as @agent_state_script.
//
// Maps OpenCode's event bus to the six words the script understands. Every call
// is fire-and-forget and swallowed on error: a broken indicator must never
// block the agent.
export const TmuxAgentState = async ({ $ }) => {
  const report = async (word) => {
    if (!process.env.TMUX) return
    try {
      await $`sh -c ${'exec "$(tmux show -gv @agent_state_script)" ' + word}`.quiet().nothrow()
    } catch {}
  }
  return {
    event: async ({ event }) => {
      switch (event.type) {
        case "session.created":
          return report("idle")
        case "message.updated": // a user message means a prompt was submitted
          if (event.properties?.info?.role === "user") return report("working")
          return
        case "tool.execute.after":
          return report("working")
        case "permission.asked":
          return report("blocked")
        case "permission.replied":
          return report("working")
        case "session.error":
          return report("blocked")
        case "session.idle":
          return report("done")
        case "session.deleted":
          return report("clear")
      }
    },
  }
}
