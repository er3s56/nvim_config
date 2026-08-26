local Menu = require("config.explorer_menu")

local function assert_equal(expected, actual, message)
  if not vim.deep_equal(expected, actual) then
    error(("%s\nexpected: %s\nactual:   %s"):format(message, vim.inspect(expected), vim.inspect(actual)))
  end
end

local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "file", "folder", "unused" })
local win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(win, buf)
local items = {
  { file = "/project/file.txt", dir = false },
  { file = "/project/folder", dir = true },
}
local list = {
  win = { win = win },
  selected = {},
  selected_map = {},
}
function list:row2idx(row)
  return row
end
function list:count()
  return #items
end
function list:get(index)
  return items[index]
end
function list:view(index)
  self.viewed = index
end
function list:is_selected(item)
  return self.selected_map[item.file] == true
end
function list:set_selected(selected)
  self.selected = selected or {}
  self.selected_map = {}
  for _, item in ipairs(self.selected) do
    self.selected_map[item.file] = true
  end
end

local picker = {
  list = list,
  closed = false,
  input = {},
}
function picker:cwd()
  return "/project"
end
function picker:selected()
  return vim.deepcopy(self.list.selected)
end

local function mouse_for_line(line)
  local position = vim.fn.screenpos(win, line, 1)
  return { winid = win, line = line, screenrow = position.row, screencol = position.col }
end

list:set_selected({ items[1], items[2] })
local selected = Menu._context_at_mouse(picker, mouse_for_line(1))
assert_equal(2, #selected.paths, "right-clicking a selected item did not preserve multiselect")
assert_equal(1, list.viewed, "right click did not position Explorer on the clicked item")
assert_equal("/project", selected.target_dir, "file paste target must be its parent")

list:set_selected({ items[1] })
local unselected = Menu._context_at_mouse(picker, mouse_for_line(2))
assert_equal({ "/project/folder" }, unselected.paths, "right-clicking an unselected item did not switch context")
assert_equal(0, #list.selected, "old multiselect was not cleared")
assert_equal("/project/folder", unselected.target_dir, "folder paste target must be the folder")

list:set_selected({ items[1] })
local blank_mouse = mouse_for_line(3)
blank_mouse.screenrow = blank_mouse.screenrow + 1
local blank = Menu._context_at_mouse(picker, blank_mouse)
assert_equal(nil, blank.item, "Explorer padding resolved to an item")
assert_equal("/project", blank.target_dir, "Explorer padding did not target cwd")
assert_equal(0, #list.selected, "right-clicking Explorer padding did not clear selection")

local labels = {}
for _, entry in ipairs(Menu._entries_for(selected)) do
  if entry.label then
    labels[entry.label] = true
  end
end
for _, label in ipairs({
  "Open",
  "Reveal in File Manager",
  "New File",
  "New Folder",
  "Copy",
  "Paste",
  "Copy Absolute Path",
  "Copy Relative Path",
  "Rename",
  "Delete",
  "Refresh",
}) do
  assert(labels[label], "missing menu entry: " .. label)
end

Menu._open(Menu._entries_for(blank), { screenrow = 1, screencol = 1 })
assert_equal("explorer_context_menu", vim.bo.filetype, "context menu float did not open")
Menu._close()
print("explorer-menu-ok")
