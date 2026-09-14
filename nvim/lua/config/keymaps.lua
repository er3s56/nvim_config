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
