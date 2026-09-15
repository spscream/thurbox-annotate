-- thurbox-annotate (Lite tier): comment on the mouse text selection and send the
-- accumulated notes back to the focused session as numbered feedback — no
-- external binary, entirely in Lua.
--
-- The selection reaches Lua through `thurbox.selection`, the published field the
-- kernel refreshes each frame (upstream since thurbox v2.25.0). The comment chord
-- is GLOBAL so it fires while the agent is focused; it grabs the selection at
-- press time — the field still carries the finished selection even though that
-- same keypress clears the live one — so the agent may then be hidden behind this
-- pane while you type the comment.
--
-- Delivery is `command("send")`, the same route the agent's composer receives a
-- prompt on, so a real agent reads the review as if you had typed it. No
-- capability is needed: unlike the Full tier there is no external program to run.
--
-- The list is a small manager, mirroring herdr-annotate's `Ctrl+B M`: a cursor
-- (j/k) selects a note, `c` cycles its classification, `x` deletes it, `a`
-- archives it and `Tab` shows the archive where `u` restores. Only the active
-- notes are sent; the archive is a holding area, not part of the review.

local theme = require("lib.theme")
local widgets = require("lib.widgets")
local textinput = require("lib.textinput")

local NAME = "notes"

--- The classifications a note can carry, in cycle order, with `note` the
--- default — the same set herdr-annotate and thurbox-code-review use.
local CLASSES = { "issue", "suggestion", "note", "praise" }
local CLASS_LABEL = { issue = "Issue", suggestion = "Suggestion", note = "Note", praise = "Praise" }
--- Class → theme ROLE name, resolved inside `render` (never captured at load, or
--- the colour would freeze across a theme switch). Falls back to `text`.
local CLASS_ROLE = { issue = "error", suggestion = "warn", note = "muted", praise = "ok" }

--- The next class in the cycle, wrapping — herdr's `Classification::next`.
local function next_class(class)
  for i, name in ipairs(CLASSES) do
    if name == class then
      return CLASSES[i % #CLASSES + 1]
    end
  end
  return CLASSES[1]
end

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
--- published `thurbox.selection` field, which the kernel refreshes every frame.
local function selection()
  local text = thurbox and thurbox.selection
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

--- Which list the cursor is over, and its name — `state` is deserialised on each
--- read, so callers take the returned list, mutate it, and write it BACK under
--- the returned key (see the write-back trap the whole pane is careful about).
local function view_of()
  return state.view == "archived" and "archived" or "notes"
end

local function list_of(view)
  if view == "archived" then
    return state.archived or {}
  end
  return state.notes or {}
end

--- The cursor clamped to the list — 1 even when empty, so a row index never
--- points past the end after a delete or an archive.
local function cursor_in(list)
  return math.max(1, math.min(state.cursor or 1, math.max(1, #list)))
end

--- The accumulated notes as numbered feedback for a composer. Plain text, since
--- that is what lands in the agent — each note is the classified quote and the
--- comment under it.
local function to_feedback(notes)
  local out = { "Review notes:", "" }
  for i, note in ipairs(notes) do
    local quote = (note.quote:gsub("%s+", " ")):gsub("^%s+", "")
    local label = CLASS_LABEL[note.class or "note"] or "Note"
    out[#out + 1] = i .. ". [" .. label .. "] > " .. quote
    out[#out + 1] = "   " .. note.comment
    out[#out + 1] = ""
  end
  return table.concat(out, "\n")
end

--- Deliver the accumulated notes to the selected session's composer, or explain
--- why it cannot. Shared by the `E` key and the `notes.send` action. Only the
--- active notes travel — the archive is deliberately left out.
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
    -- Global so it fires from the focused agent, where the selection is made,
    -- and an F-key (not `ctrl+<letter>`) for the reason the agent pane's own
    -- F-keys are: a focused terminal keeps the bare letter chords for the
    -- program inside it. F2 because the rest of the strip is taken — F5 is the
    -- Full review, F7 the editor tab, F8 the shell, F9 the sessions editor, and
    -- F1/F4/F6 are the kernel's.
    {
      key = "f2",
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
    local view = view_of()
    local list = list_of(view)
    local cursor = cursor_in(list)
    local archived = state.archived or {}
    local title = view == "archived" and ("Archived · " .. #archived)
      or (#list > 0 and ("Notes · " .. #list) or "Notes")
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

    if #list == 0 and not state.composing then
      local hint
      if view == "archived" then
        hint = "no archived notes — Tab returns to the review"
      else
        local sel = selection()
        hint = sel and ('press F2 to comment on "' .. snippet(sel, ctx.width) .. '"')
          or "select a line in the agent, then press F2 to comment on it"
      end
      children[#children + 1] = { type = "text", text = theme.dim("  " .. hint) }
    end

    for i, note in ipairs(list) do
      local selected = i == cursor
      local marker = selected and "▸ " or "  "
      local label = CLASS_LABEL[note.class or "note"] or "Note"
      local class_fg = theme[CLASS_ROLE[note.class or "note"]] or theme.text
      children[#children + 1] = {
        type = "text",
        text = {
          {
            {
              text = marker .. i .. ". ",
              style = { fg = selected and theme.accent or theme.muted },
            },
            { text = "[" .. label .. "] ", style = { fg = class_fg } },
            { text = '"', style = { fg = theme.muted } },
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
    if view == "archived" then
      children[#children + 1] = {
        type = "text",
        text = theme.dim("  j/k move · u restore · x delete · Tab review"),
      }
    elseif #list > 0 then
      children[#children + 1] = {
        type = "text",
        text = theme.dim(
          "  F2 comment · j/k move · c class · x del · a archive · Tab archive · E send"
        ),
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
          notes[#notes + 1] =
            { quote = state.pending_quote or "", comment = comment, class = "note" }
          state.notes = notes
          state.view = "notes"
          state.cursor = #notes
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

    -- Not composing: the list manager. `E` (shift) sends the active notes.
    if key.char == "E" then
      send_notes()
      return true
    end

    local view = view_of()
    local list = list_of(view)
    local cursor = cursor_in(list)

    -- Move the cursor, when there is a list to move over.
    if key.key == "j" or key.key == "down" then
      if #list > 0 then
        state.cursor = math.min(cursor + 1, #list)
      end
      return true
    end
    if key.key == "k" or key.key == "up" then
      if #list > 0 then
        state.cursor = math.max(cursor - 1, 1)
      end
      return true
    end

    -- Show the review or the archive.
    if key.key == "tab" then
      state.view = view == "notes" and "archived" or "notes"
      state.cursor = 1
      return true
    end

    -- Cycle the selected note's classification (active notes only).
    if key.key == "c" and view == "notes" then
      local notes = state.notes or {}
      local note = notes[cursor]
      if note then
        note.class = next_class(note.class or "note")
        state.notes = notes
      end
      return true
    end

    -- Archive the selected note: out of the review, into the holding area.
    if key.key == "a" and view == "notes" then
      local notes = state.notes or {}
      local note = table.remove(notes, cursor)
      if note then
        local arch = state.archived or {}
        arch[#arch + 1] = note
        state.notes = notes
        state.archived = arch
        state.cursor = math.min(cursor, math.max(1, #notes))
      end
      return true
    end

    -- Restore the selected archived note back into the review.
    if key.key == "u" and view == "archived" then
      local arch = state.archived or {}
      local note = table.remove(arch, cursor)
      if note then
        local notes = state.notes or {}
        notes[#notes + 1] = note
        state.archived = arch
        state.notes = notes
        state.cursor = math.min(cursor, math.max(1, #arch))
      end
      return true
    end

    -- Delete the selected note from whichever list the cursor is over.
    if key.key == "x" then
      if #list > 0 then
        table.remove(list, cursor)
        if view == "archived" then
          state.archived = list
        else
          state.notes = list
        end
        state.cursor = math.min(cursor, math.max(1, #list))
      end
      return true
    end

    -- Clear the whole current list — the convenience herdr leaves to archiving.
    if key.key == "d" then
      if view == "archived" then
        state.archived = {}
      else
        state.notes = {}
      end
      state.cursor = 1
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
          text = "notes: select a line in the agent first, then press F2",
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
