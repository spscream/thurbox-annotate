-- thurbox-annotate (Lite tier): comment on the mouse text selection and send the
-- accumulated notes back to the focused session as numbered feedback — no
-- external binary, entirely in Lua.
--
-- The selection reaches Lua through the shared store key `selection.text`, which
-- the kernel publishes each frame (a small fork change beside `copy_selection`).
-- The comment chord is GLOBAL so it fires while the agent is focused; it grabs
-- the selection at press time — the store still holds last frame's value even
-- though that same keypress clears the live selection — so the agent may then be
-- hidden behind this pane while you type the comment.
--
-- Delivery is `command("send")`, the same route the agent's composer receives a
-- prompt on, so a real agent reads the review as if you had typed it. No
-- capability is needed: unlike the Full tier there is no external program to run.

local theme = require("lib.theme")
local widgets = require("lib.widgets")
local textinput = require("lib.textinput")

local NAME = "notes"
local SELECTION = "selection.text"

--- The session the notes are sent to: whatever the list has selected, the same
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

--- The current mouse selection, or nil when nothing is selected. Read from the
--- shared store, where the kernel mirrors it every frame.
local function selection()
  local text = store[SELECTION]
  if type(text) == "string" and text:gsub("%s", "") ~= "" then
    return text
  end
  return nil
end

--- One line of a quote, trimmed and shortened — a note points at a line, and the
--- pane has one row to remind you which. The full quote still travels in the
--- delivered feedback.
local function snippet(quote, width)
  local line = (quote:gsub("%s+", " ")):gsub("^%s+", "")
  local limit = math.max(8, (width or 40) - 8)
  if widgets.chars(line) > limit then
    line = line:sub(1, limit) .. "…"
  end
  return line
end

--- The accumulated notes as numbered feedback for a composer. Plain text, since
--- that is what lands in the agent — each note is the quoted line and the comment
--- under it.
local function to_feedback(notes)
  local out = { "Review notes:", "" }
  for i, note in ipairs(notes) do
    local quote = (note.quote:gsub("%s+", " ")):gsub("^%s+", "")
    out[#out + 1] = i .. ". > " .. quote
    out[#out + 1] = "   " .. note.comment
    out[#out + 1] = ""
  end
  return table.concat(out, "\n")
end

--- Deliver the accumulated notes to the selected session's composer, or explain
--- why it cannot. Shared by the `E` key and the `notes.send` action.
local function send_notes()
  local notes = state.notes or {}
  if #notes == 0 then
    command("message", { text = "notes: nothing to send yet", level = "error" })
    return
  end
  local session = target()
  if not session then
    command("message", { text = "notes: select a session to send to first", level = "error" })
    return
  end
  command("send", { session = session.id, text = to_feedback(notes) })
  command("message", {
    text = "notes: sent " .. #notes .. " note(s) → " .. (session.name or session.id),
    level = "success",
  })
end

return {
  name = NAME,
  slot = "center",
  slot_mode = "switch",
  order = 31,
  focusable = true,
  pure = true,

  -- Brought forward by its pill or its chord, like the Full pane beside it.
  pills = { { action = "notes.open", label = "Notes", priority = 15 } },

  keys = {
    -- Global so it fires from the focused agent, where the selection is made.
    {
      key = "f7",
      action = "notes.comment",
      desc = "comment on the selection",
      scope = "global",
      group = "UI",
    },
  },

  commands = {
    { action = "notes.open", desc = "open the review notes" },
    { action = "notes.comment", desc = "comment on the current selection" },
    { action = "notes.send", desc = "send the notes to the focused session" },
    { action = "notes.clear", desc = "clear the review notes" },
  },

  render = function(ctx)
    local notes = state.notes or {}
    local title = #notes > 0 and ("Notes · " .. #notes) or "Notes"
    local children = { { type = "text", len = 1, text = "" } }

    if state.composing then
      children[#children + 1] = {
        type = "text",
        text = theme.dim('  on "' .. snippet(state.pending_quote or "", ctx.width) .. '"'),
      }
      local field = state.field or textinput.new("")
      children[#children + 1] = {
        type = "box",
        axis = "horizontal",
        len = 1,
        children = {
          { type = "text", len = 2, text = "  " },
          {
            type = "input",
            fill = 1,
            value = field.value or "",
            cursor = field.cursor or 0,
            placeholder = "comment · enter saves · esc cancels",
            focused = true,
            style = { fg = theme.text },
          },
        },
      }
      children[#children + 1] = { type = "text", len = 1, text = "" }
    end

    if #notes == 0 and not state.composing then
      local sel = selection()
      local hint = sel and ('press F7 to comment on "' .. snippet(sel, ctx.width) .. '"')
        or "select a line in the agent, then press F7 to comment on it"
      children[#children + 1] = { type = "text", text = theme.dim("  " .. hint) }
    end

    for i, note in ipairs(notes) do
      children[#children + 1] = {
        type = "text",
        text = {
          {
            { text = "  " .. i .. '. "', style = { fg = theme.muted } },
            { text = snippet(note.quote, ctx.width), style = { fg = theme.accent } },
            { text = '"', style = { fg = theme.muted } },
          },
        },
      }
      children[#children + 1] = {
        type = "text",
        text = { { { text = "     " .. note.comment, style = { fg = theme.text } } } },
      }
    end

    children[#children + 1] = { type = "text", fill = 1, text = "" }
    if #notes > 0 then
      children[#children + 1] = {
        type = "text",
        text = theme.dim("  F7 comment · E send · d clear"),
      }
    end

    return {
      type = "box",
      frame = widgets.panel(title, ctx.focused),
      children = children,
    }
  end,

  on_key = function(key)
    -- While composing, the field owns the text keys; enter saves, esc cancels.
    if state.composing then
      -- Read the field into a local, mutate that, then write it BACK: `state` is
      -- deserialised on each read, so a field mutated in place is silently lost.
      local field = state.field or textinput.new("")
      if key.key == "enter" then
        local comment = (field.value or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if comment ~= "" then
          local notes = state.notes or {}
          notes[#notes + 1] = { quote = state.pending_quote or "", comment = comment }
          state.notes = notes
        end
        state.composing = false
        state.field = textinput.new("")
        state.pending_quote = nil
        return true
      end
      if key.key == "esc" then
        state.composing = false
        state.field = textinput.new("")
        state.pending_quote = nil
        return true
      end
      textinput.key(field, key)
      state.field = field
      return true
    end

    -- Not composing: the list's own keys. `E` (shift) sends, `d` clears.
    if key.char == "E" then
      send_notes()
      return true
    end
    if key.key == "d" then
      state.notes = {}
      return true
    end
    return false
  end,

  on_action = function(action)
    if action == "notes.open" then
      command("focus", { text = NAME, toggle = true })
      return true
    end

    if action == "notes.comment" then
      command("focus", { text = NAME })
      local sel = selection()
      if not sel then
        command("message", {
          text = "notes: select a line in the agent first, then press F7",
          level = "error",
        })
        return true
      end
      state.pending_quote = sel
      state.field = textinput.new("")
      state.composing = true
      return true
    end

    if action == "notes.send" then
      send_notes()
      return true
    end

    if action == "notes.clear" then
      state.notes = {}
      state.composing = false
      state.pending_quote = nil
      return true
    end

    return false
  end,
}
