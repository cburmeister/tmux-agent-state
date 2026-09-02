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
  // Subagents run in child sessions that fire their own lifecycle events: a
  // child's session.idle would flip the tab to done mid-turn while the parent
  // still works. A session created with a parentID is a child, and its
  // lifecycle events are dropped. permission.asked is never filtered: a child
  // asking for permission still needs the user.
  const children = new Set()
  const isChild = (id) => id != null && children.has(id)
  // message.updated re-fires for a user message when its record is finalized
  // at turn end, which would flip a fresh done back to working; only the first
  // sighting of a message id counts as a submitted prompt. The set is capped,
  // dropping the oldest id first: a re-fire lands close to its first sighting,
  // so a long-lived process stays bounded without losing the dedupe.
  const seenUserMessages = new Set()
  return {
    event: async ({ event }) => {
      const p = event.properties ?? {}
      switch (event.type) {
        case "session.created":
          if (p.info?.parentID) return void children.add(p.info.id)
          return report("idle")
        case "message.updated": { // a user message means a prompt was submitted
          const m = p.info ?? {}
          if (m.role !== "user" || isChild(m.sessionID) || seenUserMessages.has(m.id)) return
          if (m.id != null) {
            seenUserMessages.add(m.id)
            if (seenUserMessages.size > 500) seenUserMessages.delete(seenUserMessages.values().next().value)
          }
          return report("working")
        }
        case "tool.execute.after":
          return report("working")
        case "permission.asked":
          return report("blocked")
        case "permission.replied":
          return report("working")
        case "session.error":
          if (isChild(p.sessionID)) return
          return report("blocked")
        case "session.idle":
          if (isChild(p.sessionID)) return
          return report("done")
        case "session.deleted":
          if (p.info?.id != null && children.delete(p.info.id)) return
          return report("clear")
      }
    },
  }
}
