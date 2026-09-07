-- Every yes/no question in this configuration must be the same widget, and
-- that widget must answer to a single click.
--
-- The bug this guards against was not a missing abstraction: `ContextMenu`
-- already modelled a menu as data and already activated a row on one press.
-- Two modules simply went around it -- one to `Snacks.picker.util.confirm`,
-- one to `vim.ui.select` -- and in a picker a lone click only moves the
-- cursor. The result was a Delete dialog whose "Yes" did nothing, silently,
-- while the Git panel three windows over confirmed on the first click. An
-- abstraction cannot stop a caller from not using it, so the rule is asserted
-- here instead.
local ContextMenu = require("config.context_menu")

local root = vim.fn.stdpath("config") .. "/lua/config"

-- Prompting through a picker is what broke; name the ways in, not the fix, so
-- a new picker-based prompt is caught rather than a renamed helper.
local FORBIDDEN = {
  ["vim%.ui%.select"] = "vim.ui.select",
  ["Snacks%.picker%.util%.confirm"] = "Snacks.picker.util.confirm",
}

local offences = {}
for name, kind in vim.fs.dir(root) do
  if kind == "file" and name:match("%.lua$") then
    local path = root .. "/" .. name
    local line_number = 0
    for line in io.lines(path) do
      line_number = line_number + 1
      -- Prose may name these freely; only code counts.
      if not line:match("^%s*%-%-") then
        for pattern, label in pairs(FORBIDDEN) do
          if line:match(pattern) then
            offences[#offences + 1] = ("%s:%d uses %s"):format(name, line_number, label)
          end
        end
      end
    end
  end
end

assert(
  #offences == 0,
  table.concat({
    "a modal choice is being asked through a picker, where one click does nothing:",
    table.concat(offences, "\n"),
    "use ContextMenu.confirm instead -- see the note above it.",
  }, "\n")
)

-- The contract itself: a press on the proceeding row runs it, on the first
-- press, with no pointer travel in between.
local proceeded, cancelled = false, false
ContextMenu.confirm("Delete everything?", "Delete", { screenrow = 1, screencol = 1 }, function()
  proceeded = true
end)

assert(vim.bo.filetype == "confirm_menu", "confirm did not open the shared menu widget")
local win = assert(ContextMenu._window(), "confirm did not record an open menu window")
local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
assert(lines[1]:find("Delete everything?", 1, true), "confirm did not show the question")
assert(lines[3]:find("Delete", 1, true), "confirm did not offer the proceeding row")
assert(lines[4]:find("Cancel", 1, true), "confirm did not offer a cancelling row")

-- A confirmation opens on its cancelling row, so <CR> declines. Every question
-- asked through `confirm` is destructive, which makes the row the cursor lands
-- on a safety decision rather than a cosmetic one: a mistaken decline costs a
-- keystroke, a mistaken proceed costs work.
assert(
  vim.api.nvim_win_get_cursor(win)[1] == 4,
  ("a confirmation opened focused on row %d, not on its cancelling row"):format(
    vim.api.nvim_win_get_cursor(win)[1]
  )
)

ContextMenu._press({ winid = win, line = 3 })
assert(
  vim.wait(1000, function()
    return proceeded
  end),
  "a single press on the proceeding row did not confirm"
)

-- And the cancelling row really does nothing but close.
ContextMenu.confirm("Delete everything?", "Delete", { screenrow = 1, screencol = 1 }, function()
  cancelled = true
end)
win = assert(ContextMenu._window())
ContextMenu._press({ winid = win, line = 4 })
vim.wait(200)
assert(not cancelled, "the cancelling row ran the action")
assert(ContextMenu._window() == nil, "cancelling left the menu open")

-- A caller with no pointer still gets a menu rather than an error.
ContextMenu.confirm("No pointer here?", "Proceed", nil, function() end)
assert(ContextMenu._window(), "confirm without a mouse position did not open")
ContextMenu.close()

print("modal-choice-ok")
