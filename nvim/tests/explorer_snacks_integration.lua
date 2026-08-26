local Menu = require("config.explorer_menu")

assert(rawget(_G, "Snacks") and Snacks.picker, "Snacks must be loaded by the real config")
local mapping = vim.fn.maparg("<RightMouse>", "n", false, true)
assert(type(mapping.callback) == "function", "shared right-click dispatcher is not registered")
assert(mapping.callback() == "<RightMouse>", "right click outside Explorer no longer passes through")

local root = vim.fn.tempname()
local file = vim.fs.joinpath(root, "file.txt")
local folder = vim.fs.joinpath(root, "folder")
vim.fn.mkdir(folder, "p")
assert(vim.fn.writefile({ "item" }, file) == 0)

local picker
local ok, test_err = pcall(function()
  picker = Snacks.explorer({
    cwd = root,
    watch = false,
    follow_file = false,
    diagnostics = false,
    git_status = false,
  })
  assert(picker, "Snacks Explorer did not open")
  assert(picker.opts.hidden == true, "Explorer does not show hidden files by default")
  assert(picker.opts.ignored == true, "Explorer does not show ignored files by default")
  assert(
    vim.wait(3000, function()
      return picker.list and picker.list:count() >= 2 and picker.list.win and picker.list.win:valid()
    end),
    "Snacks Explorer finder did not populate"
  )

  local file_item, folder_item, file_index
  for index = 1, picker.list:count() do
    local item = picker.list:get(index)
    if item and item.file == file then
      file_item, file_index = item, index
    elseif item and item.file == folder then
      folder_item = item
    end
  end
  assert(file_item and folder_item and file_index, "Explorer items were not found")

  picker.list:view(file_index)
  picker.list:set_selected({ file_item, folder_item })
  vim.cmd.redraw()
  local win = picker.list.win.win
  local row = picker.list:idx2row(file_index)
  local position = vim.fn.screenpos(win, row, 1)
  local context = Menu._context_at_mouse(picker, {
    winid = win,
    line = row,
    screenrow = position.row,
    screencol = position.col,
  })
  assert(#context.paths == 2, "real Snacks multiselect was not preserved")
  assert(context.target_dir == root, "real Snacks file target was not its parent directory")

  Menu._open(Menu._entries_for(context), { screenrow = position.row, screencol = position.col })
  assert(vim.bo.filetype == "explorer_context_menu", "Explorer context float did not open with Snacks")
  Menu._close()
end)

Menu._close()
if picker and not picker.closed then
  picker:close()
end
vim.fn.delete(root, "rf")
assert(ok, test_err)
print("explorer-snacks-integration-ok")
