-- thurbox-annotate (Full tier): review the focused agent's output in
-- plannotator-tui, and send the numbered feedback back to that same agent.
--
-- plannotator-tui is an external terminal program, so this is a PROGRAM pane:
-- the kernel fills our `surface` with its cells, and we own when it starts and
-- stops. *What* it reviews and *where* feedback goes are decided by a shipped
-- launcher (bin/pt-launch.sh), not here — a program pane cannot be handed
-- environment variables, so the whole herdr contract (capture → open → deliver)
-- is assembled in that script. We only pass it the target session.

local theme = require("lib.theme")
local widgets = require("lib.widgets")

local NAME = "annotate"
local PROGRAM = "review"

--- The session whose output we review: whatever the list has selected, the same
--- one the agent pane shows.
local function target()
  local id = store.selected
  if not id then
    return nil
  end
  for _, session in ipairs((thurbox and thurbox.sessions) or {}) do
    if session.id == id then
      return session
    end
  end
  return nil
end

--- A framed message — the states before a program is on screen. Deliberately
--- not blank and not an error: honest about what the pane needs next.
local function message(title, ctx, line)
  return {
    type = "box",
    frame = widgets.panel(title, ctx.focused),
    children = {
      { type = "text", len = 1, text = "" },
      { type = "text", text = theme.dim("  " .. line) },
    },
  }
end

return {
  name = NAME,
  slot = "center",
  slot_mode = "switch",
  order = 30,
  focusable = true,
  -- Keys we do not declare go to plannotator-tui in the surface.
  input = "session",
  capabilities = { "program" },

  -- Shares the `center` switch slot with the agent pane, so it draws nothing
  -- until brought forward: the action band offers this.
  pills = { { action = "annotate.open", label = "Review", priority = 20 } },

  keys = {
    {
      key = "f5",
      action = "annotate.open",
      desc = "review the agent output",
      scope = "global",
      group = "UI",
    },
  },

  commands = {
    { action = "annotate.open", desc = "review the focused agent's output" },
  },

  -- A program pane is told when its program ends, so the surface does not sit on
  -- a dead process.
  events = { "program.exited" },
  on_event = function(name)
    if name == "program.exited" then
      state.open = false
    end
  end,

  render = function(ctx)
    -- Through a local so the static path check stops here: `thurbox.granted` is a
    -- declared leaf, and `.program` is a field the sandbox lint would otherwise
    -- reject as unknown.
    local granted = (thurbox and thurbox.granted) or {}
    if not granted.program then
      return message(
        "Review",
        ctx,
        "trust this pane in settings → Interface → t for plannotator-tui"
      )
    end
    if not state.open then
      return message("Review", ctx, "press F5 to review the focused agent's output")
    end
    local session = target()
    if not session then
      return message("Review", ctx, "select a session to review first")
    end
    -- Idempotent: asking again while it runs does nothing, so calling every
    -- frame is correct. The launcher lives beside this file in the cloned repo.
    local launcher = (thurbox.ui_dir or "") .. "/thurbox-annotate/bin/pt-launch.sh"
    command("program", {
      text = PROGRAM,
      repo = launcher,
      args = { state.review_id or session.id, state.review_label or session.name or session.id },
    })
    return { type = "surface", program = PROGRAM, fill = 1 }
  end,

  on_action = function(action)
    if action ~= "annotate.open" then
      return false
    end
    if state.open then
      -- One key both enters and leaves: close the program and hand focus back.
      command("program", { text = PROGRAM, action = "close" })
      state.open = false
      command("focus", { text = NAME, toggle = true })
      return true
    end
    local session = target()
    if not session then
      command("message", { text = "annotate: select a session to review first", level = "error" })
      return true
    end
    -- Pin the target at open time: the launcher captures THIS session even if the
    -- list selection moves while the review is up.
    state.open = true
    state.review_id = session.id
    state.review_label = session.name or session.id
    command("focus", { text = NAME })
    return true
  end,
}
