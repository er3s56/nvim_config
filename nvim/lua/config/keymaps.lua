-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

-- Find in File: a search strip under the editor, one per buffer. Takes the
-- place of a page-down nobody scrolls with; <C-d> and the wheel remain.
vim.keymap.set("n", "<C-f>", function()
  require("config.find_in_file").open()
end, { desc = "Find in file" })
vim.keymap.set("x", "<C-f>", function()
  require("config.find_in_file").open_selection()
end, { desc = "Find selection in file" })
-- From Insert mode too, the way an editor find box opens mid-typing. Insert
-- mode carries over into the strip and ends when the strip closes, which
-- leaves the editor in Normal mode with the cursor where Esc would put it.
vim.keymap.set("i", "<C-f>", function()
  require("config.find_in_file").open()
end, { desc = "Find in file" })

-- The keys an editor puts on its panels, on top of what LazyVim binds. The
-- pickers open where they are; the panels are focused, not merely shown,
-- since the key is pressed to go there -- except Ctrl+B, which only shows
-- or hides the sidebar and leaves the focus where it was.
--
-- Ctrl+Shift+<letter> needs a terminal that speaks the kitty keyboard
-- protocol; the legacy encoding has no room for Shift and delivers the plain
-- Ctrl key, which then does its own thing. Windows Terminal has the protocol
-- from 1.25 on (Preview, as of 2026-09); nvim negotiates it by itself.
local function map(modes, lhs, rhs, desc)
  vim.keymap.set(modes, lhs, rhs, { desc = desc })
end

map("n", "<C-p>", function()
  LazyVim.pick("files")()
end, "Quick open")
-- The Ctrl+Shift keys work from the terminal too, as they do in an editor;
-- Ctrl+P and Ctrl+B do not, being a shell's history and a multiplexer's
-- prefix there.
map({ "n", "i", "t" }, "<C-S-p>", function()
  vim.cmd.stopinsert()
  Snacks.picker.commands()
end, "Command palette")
map({ "n", "i", "t" }, "<C-S-f>", function()
  require("config.activity_bar").search()
end, "Search in project")
map("x", "<C-S-f>", function()
  local lines = vim.fn.getregion(vim.fn.getpos("v"), vim.fn.getpos("."), { type = vim.fn.mode() })
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  require("config.activity_bar").search(#lines == 1 and lines[1] or nil)
end, "Search selection in project")
map({ "n", "i", "t" }, "<C-S-e>", function()
  vim.cmd.stopinsert()
  require("config.activity_bar").open("explorer", { focus = true })
end, "Explorer")
map({ "n", "i", "t" }, "<C-S-g>", function()
  vim.cmd.stopinsert()
  require("config.activity_bar").open("git", { focus = true })
end, "Git panel")
map({ "n", "i" }, "<C-b>", function()
  local ActivityBar = require("config.activity_bar")
  local state = ActivityBar.current()
  ActivityBar.toggle(state and state.view or "explorer", { focus = false })
end, "Toggle sidebar")
-- Ctrl+` is the key; Ctrl+/ is what LazyVim gave the terminal, and some
-- terminals send Ctrl+/ as Ctrl+_. All three reach the project terminal,
-- not the plain Snacks one LazyVim opens.
for _, key in ipairs({ "<C-`>", "<C-/>", "<C-_>" }) do
  map({ "n", "i", "t" }, key, function()
    vim.cmd.stopinsert()
    require("config.git_panel").toggle_terminal()
  end, "Toggle terminal")
end
