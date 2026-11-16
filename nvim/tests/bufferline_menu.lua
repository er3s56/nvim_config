local ContextMenu = require("config.context_menu")
require("lazy").load({ plugins = { "bufferline.nvim" } })

local function listed(buf)
  return vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buflisted
end
local function wait_for(predicate, message)
  assert(vim.wait(1000, predicate, 10), message)
end
local function open_menu(buf)
  ___bufferline_private.handle_click(buf, 1, "r")
  wait_for(function()
    return ContextMenu._window() ~= nil
  end, "right click did not open the menu")
  assert(listed(buf), "right click closed the file before an action was chosen")
end
local function choose(label)
  local win = assert(ContextMenu._window())
  local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
  for row, line in ipairs(lines) do
    if vim.trim(line) == label then
      ContextMenu._press({ winid = win, line = row })
      wait_for(function()
        return ContextMenu._window() == nil
      end, "menu did not close")
      vim.wait(50, function()
        return false
      end)
      return
    end
  end
  error("menu entry missing: " .. label)
end

local original = vim.api.nvim_get_current_buf()
local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/docs", "p")
local buffers = {}
for _, name in ipairs({ "left.md", "clicked.md", "right.md", "moved.md" }) do
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, root .. "/docs/" .. name)
  buffers[#buffers + 1] = buf
end
local left, clicked, right, moved = unpack(buffers)
vim.api.nvim_set_current_buf(left)
vim.bo[original].buflisted = false
-- Display order differs from creation order: closing to the right must use
-- the tabs the reader sees, not buffer numbers or the currently active tab.
require("bufferline.state").set({ custom_sort = { moved, left, clicked, right } })
nvim_bufferline()
local ids = vim.tbl_map(function(e)
  return e.id
end, require("bufferline").get_elements().elements)
assert(vim.deep_equal(ids, { moved, left, clicked, right }), "test tabs were not reordered")

open_menu(clicked)
assert(not vim.tbl_contains(vim.api.nvim_buf_get_lines(0, 0, -1, false), "  Open"), "redundant Open entry remains")
assert(vim.api.nvim_win_get_buf(vim.fn.win_getid(vim.fn.winnr("#"))) == left, "opening a menu switched files")
vim.fn.maparg("<Esc>", "n", false, true).callback()
assert(listed(clicked) and not ContextMenu._window(), "Esc did not dismiss without closing")

nvim_bufferline()
open_menu(clicked)
choose("Close to the Right")
assert(not listed(right), "the tab to the right was not closed")
assert(listed(left) and listed(clicked) and listed(moved), "Close to the Right closed a tab on the left")

local copied
local setreg = vim.fn.setreg
vim.fn.setreg = function(register, text, kind)
  copied = { register, text, kind }
end
open_menu(clicked)
choose("Copy Absolute Path")
assert(vim.deep_equal(copied, { "+", vim.api.nvim_buf_get_name(clicked), "c" }), "wrong path or clipboard format")
local project_root = LazyVim.root
LazyVim.root = function()
  return root
end
open_menu(clicked)
choose("Copy Relative Path")
assert(vim.deep_equal(copied, { "+", "docs/clicked.md", "c" }), "path is not relative to the project root")
LazyVim.root = function()
  return root .. "/another-project"
end
open_menu(clicked)
choose("Copy Relative Path")
assert(
  vim.deep_equal(copied, { "+", vim.api.nvim_buf_get_name(clicked), "c" }),
  "outside-project path lost its absolute fallback"
)
LazyVim.root = project_root
vim.fn.setreg = setreg

vim.api.nvim_buf_set_lines(clicked, 0, -1, false, { "unsaved edit" })
local confirm = vim.fn.confirm
local prompted = false
vim.fn.confirm = function()
  prompted = true
  return 3 -- Cancel the existing save/discard/cancel prompt.
end
open_menu(clicked)
choose("Close")
vim.fn.confirm = confirm
assert(prompted and listed(clicked) and vim.bo[clicked].modified, "Close discarded modified content")

nvim_bufferline()
open_menu(clicked)
choose("Close Others")
assert(listed(clicked) and not listed(left) and not listed(moved), "Close Others used the wrong target")

vim.bo[clicked].modified = false
open_menu(clicked)
choose("Close")
assert(not listed(clicked), "Close did not close the clicked tab")
vim.fn.delete(root, "rf")
print("bufferline-menu-ok")
