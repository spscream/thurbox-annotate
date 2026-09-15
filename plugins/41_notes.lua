-- thurbox-annotate (Lite tier): comment on the selected line of an agent's output
-- and send the accumulated notes back to the focused session as numbered
-- feedback — no external binary, entirely in Lua.
--
-- Getting the selected text takes two channels, the way herdr-annotate does:
--   1. `thurbox.selection`, the field the kernel publishes (upstream since
--      v2.25.0) for a selection THURBOX itself made — a plain shell or any pane
--      not tracking the mouse. Instant, no capability.
--   2. The system clipboard, for a selection the FOCUSED PROGRAM made. A mouse
--      drag over a tracking agent (Claude Code) is forwarded to that program, so
--      thurbox never sees the selection — but the agent's own copy-on-select has
--      put the text on the clipboard, which is exactly what herdr-annotate reads.
--      We read it with `run` (needs the `run` capability, granted per file in
--      settings) via the platform's clipboard tool. This channel is ASYNC: the
--      answer lands a frame or two after F2, so the compose row says "reading
--      clipboard…" until it does.
-- The chord is GLOBAL so it fires while the agent is focused; channel 1 is grabbed
-- at press time, channel 2 is kicked off then and read back as it arrives — so the
-- agent may be hidden behind this pane by the time you type the comment.
--
-- Delivery is `command("send")`, the same route the agent's composer receives a
-- prompt on, so a real agent reads the review as if you had typed it.
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
--- This is channel 1: only a selection thurbox itself made lands here.
local function selection()
  local text = thurbox and thurbox.selection
  if type(text) == "string" and text:gsub("%s", "") ~= "" then
    return text
  end
  return nil
end

--- Read the system clipboard — channel 2. herdr-annotate reads this same source;
--- only the tool differs by platform, so try them in order and take the first
--- that answers: PowerShell under WSL/Windows, wl-paste on Wayland, xclip/xsel on
--- X11, pbpaste on macOS. A missing tool exits non-zero and the next one runs.
--- `Get-Clipboard` writes in the console's OEM code page (CP866 for Cyrillic), so
--- it is forced to UTF-8 first — otherwise non-ASCII comes back as mojibake.
local CLIP_CMD = table.concat({
  'powershell.exe -NoProfile -Command "[Console]::OutputEncoding=[Text.Encoding]::UTF8; Get-Clipboard" 2>/dev/null',
  "wl-paste --no-newline 2>/dev/null",
  "xclip -selection clipboard -o 2>/dev/null",
  "xsel -b 2>/dev/null",
  "pbpaste 2>/dev/null",
}, " || ")

--- Normalise a captured block while KEEPING its shape: CRLF to LF, trailing
--- whitespace off each line (terminal cells copy padded, and that padding is not
--- structure), and surrounding blank lines dropped. Leading indentation is left
--- alone — it is the formatting the delivered feedback is meant to preserve, so a
--- code selection reaches the agent still indented. `Get-Clipboard`'s trailing
--- newline goes with the outer-blank trim.
local function normalize_block(s)
  s = (s or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  s = s:gsub("[ \t]+\n", "\n"):gsub("[ \t]+$", "")
  return (s:gsub("^\n+", ""):gsub("\n+$", ""))
end

--- A fenced-block delimiter that cannot be closed early by the quote's own
--- content: one backtick longer than the longest backtick run inside it, floor 3.
local function fence_for(s)
  local longest = 0
  for run in s:gmatch("`+") do
    longest = math.max(longest, #run)
  end
  return string.rep("`", math.max(3, longest + 1))
end

--- The clipboard read for the compose in flight, as one of: "off" (none in
--- flight — channel 1 supplied the quote), "waiting" (kicked off, not answered),
--- "empty" (answered with nothing usable) or the captured text. `run` is only
--- ASKED here — nothing is written — so the pane stays `pure`; asking every frame
--- is how the answer is read back (README: "Asking every frame is correct").
local function clip_status()
  local key = state.clip_key
  if type(key) ~= "string" then
    return "off"
  end
  if run and type(state.clip_session) == "string" then
    run(key, CLIP_CMD, { session = state.clip_session, ttl = 3600 })
  end
  local answer = (thurbox.runs or {})[key]
  if not answer or answer.state ~= "done" then
    return "waiting"
  end
  if not answer.ok then
    return "empty"
  end
  local text = normalize_block(answer.stdout)
  return text ~= "" and text or "empty"
end

--- The quote for the compose in flight: channel 1's instant selection if we had
--- one, else channel 2's clipboard once it is in. nil while the clipboard read is
--- still out or came back empty — so a note is never saved pointing at nothing.
local function pending_quote()
  if type(state.pending_quote) == "string" and state.pending_quote ~= "" then
    return state.pending_quote
  end
  local clip = clip_status()
  if clip == "off" or clip == "waiting" or clip == "empty" then
    return nil
  end
  return clip
end

--- One line of a quote, trimmed and shortened — a note points at a line, and the
--- pane has one row to remind you which. The full quote still travels in the
--- delivered feedback. Cutting is delegated to `widgets.truncate`: it measures in
--- columns with the painter's own `unicode-width` and never splits a codepoint,
--- where a byte-wise `line:sub(1, limit)` would leave half a Cyrillic letter — a
--- stray `�` at the cut.
local function snippet(quote, width)
  local line = (quote:gsub("%s+", " ")):gsub("^%s+", "")
  local limit = math.max(8, (width or 40) - 8)
  return widgets.truncate(line, limit)
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
--- comment under it. The quote keeps its shape: a single line stays inline after
--- `>`, a multi-line selection travels verbatim inside a fenced block, so line
--- breaks and indentation reach the agent as selected instead of collapsing to
--- one line.
local function to_feedback(notes)
  local out = { "Review notes:", "" }
  for i, note in ipairs(notes) do
    local quote = normalize_block(note.quote)
    local label = CLASS_LABEL[note.class or "note"] or "Note"
    if quote:find("\n") then
      out[#out + 1] = i .. ". [" .. label .. "]"
      local fence = fence_for(quote)
      out[#out + 1] = fence
      for line in (quote .. "\n"):gmatch("(.-)\n") do
        out[#out + 1] = line
      end
      out[#out + 1] = fence
    else
      out[#out + 1] = i .. ". [" .. label .. "] > " .. quote
    end
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

  -- For channel 2 only: reading the system clipboard when the focused program,
  -- not thurbox, made the selection. Channel 1 needs nothing; until the user
  -- grants this, `run` is nil and the pane says so instead of reading.
  capabilities = { "run" },

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
    local children = {}
    -- A leading blank for the list views; compose skips it so the quote gets that
    -- row too — on a short pane every row of code counts.
    if not state.composing then
      children[#children + 1] = { type = "text", len = 1, text = "" }
    end

    if state.composing then
      local quote = pending_quote()
      if quote then
        -- The whole selection shown verbatim, line by line — breaks and
        -- indentation kept (a code selection reads as code), never reflowed the
        -- way `wrap` would. Each source line is its own row under a 2-column
        -- margin; the painter clips a line too wide for the pane. Capped so a
        -- large paste cannot push the field off-screen — the whole quote is still
        -- stored and delivered — with the last row spent on a count of the rest.
        children[#children + 1] = { type = "text", len = 1, text = theme.dim("  on:") }
        -- Fill the pane: the quote takes every row left after the frame (2), the
        -- `on:` label (1) and the field (1). No artificial ceiling — a taller pane
        -- shows more. On overflow the last of these rows is the "+N more" count.
        local cap = math.max(1, (ctx.height or 24) - 4)
        local lines = {}
        for line in (normalize_block(quote) .. "\n"):gmatch("(.-)\n") do
          lines[#lines + 1] = line
        end
        local shown, more = #lines, 0
        if shown > cap then
          shown = math.max(1, cap - 1)
          more = #lines - shown
        end
        for j = 1, shown do
          children[#children + 1] = {
            type = "text",
            len = 1,
            text = { { { text = "  " .. lines[j], style = { fg = theme.accent } } } },
          }
        end
        if more > 0 then
          children[#children + 1] =
            { type = "text", len = 1, text = theme.dim("  … +" .. more .. " more line(s)") }
        end
      else
        local caption
        if not run and type(state.clip_key) == "string" then
          caption = "grant 'run' (Ctrl+, → ] → t) to read the clipboard"
        elseif clip_status() == "empty" then
          caption = "clipboard empty — esc, select a line, then F2 again"
        else
          caption = "reading clipboard…"
        end
        children[#children + 1] = { type = "text", len = 1, text = theme.dim("  " .. caption) }
      end
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
      children[#children + 1] = { type = "text", len = 1, text = theme.dim("  " .. hint) }
    end

    for i, note in ipairs(list) do
      local selected = i == cursor
      local marker = selected and "▸ " or "  "
      local label = CLASS_LABEL[note.class or "note"] or "Note"
      local class_fg = theme[CLASS_ROLE[note.class or "note"]] or theme.text
      children[#children + 1] = {
        type = "text",
        len = 1,
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
        len = 1,
        text = { { { text = "     " .. note.comment, style = { fg = theme.text } } } },
      }
    end

    children[#children + 1] = { type = "text", fill = 1, text = "" }
    if view == "archived" then
      children[#children + 1] = {
        type = "text",
        len = 1,
        text = theme.dim("  j/k move · u restore · x delete · Tab review"),
      }
    elseif #list > 0 then
      children[#children + 1] = {
        type = "text",
        len = 1,
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
        local quote = pending_quote()
        if comment ~= "" and not quote then
          -- The comment is ready but the quote is not: the clipboard read has
          -- not landed, or came back empty. Hold the compose open and say why,
          -- rather than save a note that points at nothing.
          command("message", {
            text = "notes: no selection captured yet — esc, select a line, then F2",
            level = "error",
          })
          return true
        end
        if comment ~= "" and quote then
          local notes = state.notes or {}
          notes[#notes + 1] = { quote = quote, comment = comment, class = "note" }
          state.notes = notes
          state.view = "notes"
          state.cursor = #notes
        end
        state.composing = false
        state.field = textinput.new("")
        state.pending_quote = nil
        state.clip_key = nil
        return true
      end
      if key.key == "esc" then
        state.composing = false
        state.field = textinput.new("")
        state.pending_quote = nil
        state.clip_key = nil
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
      state.field = textinput.new("")
      state.pending_quote = nil
      state.clip_key = nil

      -- Channel 1: a selection thurbox made itself (a non-tracking pane). Instant.
      local sel = selection()
      if sel then
        state.pending_quote = sel
        state.composing = true
        return true
      end

      -- Channel 2: the focused program made the selection and copied it (Claude
      -- Code and the like). Read the clipboard — needs `run` granted and a
      -- session to run it in.
      if not run then
        command("message", {
          text = "notes: grant 'run' (Ctrl+, → ] → t) so Lite can read the clipboard, "
            .. "or select in a non-tracking pane",
          level = "error",
        })
        return true
      end
      local session = store.selected
      if type(session) ~= "string" then
        command("message", {
          text = "notes: select a session first, then a line in it, then F2",
          level = "error",
        })
        return true
      end
      -- A fresh key per press (no os/random in the sandbox — a persisted counter)
      -- so each F2 captures the clipboard anew instead of reusing a cached read.
      state.clip_seq = (state.clip_seq or 0) + 1
      state.clip_key = "clip:" .. state.clip_seq
      state.clip_session = session
      state.composing = true
      -- Kick it now so the read is already in flight by the first render.
      run(state.clip_key, CLIP_CMD, { session = session, ttl = 3600 })
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
      state.clip_key = nil
      return true
    end

    return false
  end,
}
