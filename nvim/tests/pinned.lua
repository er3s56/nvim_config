local ActivityBar = require("config.activity_bar")
local Menu = require("config.explorer_menu")
local Pinned = require("config.pinned")

local root = vim.fn.tempname()
local outside = vim.fn.tempname()
vim.fn.mkdir(root .. "/drivers", "p")
vim.fn.mkdir(outside .. "/mirror", "p")

local original_cwd = vim.fn.getcwd(0)
local original_columns = vim.o.columns

local function wait_for(condition, message)
  assert(vim.wait(5000, condition, 50), message)
end

local function lines()
  local panel = Pinned._panel()
  return panel and vim.api.nvim_buf_get_lines(panel.buf, 0, -1, false) or {}
end

local function line_with(needle)
  for index, text in ipairs(lines()) do
    if text:find(needle, 1, true) then
      return index
    end
  end
end

local ok, test_error = pcall(function()
  vim.fn.writefile({ "int driver = 1;" }, root .. "/drivers/main.c")
  vim.fn.writefile({ "notes" }, root .. "/notes.txt")
  Pinned.setup({ file = root .. "/pins.json" })

  -- ── the list ──────────────────────────────────────────────────────────
  assert(#Pinned.list(root) == 0, "a project nobody has pinned anything in is not empty")
  assert(Pinned.add(root, root .. "/drivers"), "pinning a directory failed")
  assert(not Pinned.add(root, root .. "/drivers"), "the same path was pinned twice")
  assert(Pinned.add(root, outside .. "/mirror"), "a path outside the project could not be pinned")
  assert(Pinned.is_pinned(root, root .. "/drivers"), "a pinned path does not report as pinned")
  assert(not Pinned.is_pinned(root, root .. "/notes.txt"), "an unpinned path reports as pinned")
  assert(#Pinned.list(root) == 2, "the list does not hold both pins")
  assert(Pinned.list(root)[1]:find("drivers", 1, true), "pins are not in the order they were made")

  -- A pin outlives the session: this is the whole point of writing it down.
  Pinned.setup({ file = root .. "/pins.json" })
  assert(#Pinned.list(root) == 2, "the pins were not read back from disk")
  assert(Pinned.remove(root, outside .. "/mirror"), "unpinning failed")
  assert(#Pinned.list(root) == 1, "unpinning did not shorten the list")
  Pinned.setup({ file = root .. "/pins.json" })
  assert(#Pinned.list(root) == 1, "unpinning was not written down")

  -- ── the panel ─────────────────────────────────────────────────────────
  vim.cmd.cd(vim.fn.fnameescape(root))
  vim.o.columns = 160
  ActivityBar.setup()
  ActivityBar.open("explorer", { focus = false })
  wait_for(function()
    return Pinned._panel() ~= nil
  end, "the pinned panel never opened with the Explorer")
  local panel = Pinned._panel()

  assert(lines()[1]:find("PINNED", 1, true), "the panel has no heading")
  assert(line_with("drivers"), "a pinned directory has no row")

  -- It is stacked above the file tree, in the sidebar's own column: a pin is
  -- part of the Explorer, not a window of its own somewhere on the edge.
  local tree = assert(ActivityBar._content_root(ActivityBar.current().content), "the Explorer has no root window")
  local mine = vim.api.nvim_win_get_position(panel.win)
  local theirs = vim.api.nvim_win_get_position(tree)
  assert(mine[2] == theirs[2], "the pinned panel is not in the sidebar column")
  assert(mine[1] < theirs[1], "the pinned panel is not above the file tree")
  assert(
    vim.api.nvim_win_get_width(panel.win) == vim.api.nvim_win_get_width(tree),
    "the pinned panel is not as wide as the sidebar"
  )

  -- The panel is exactly as tall as it has rows, and no taller.
  local tall = vim.api.nvim_win_get_height(panel.win)
  assert(tall == #lines(), ("the panel is %d rows tall for %d lines"):format(tall, #lines()))
  Pinned.add(root, root .. "/notes.txt")
  assert(line_with("notes.txt"), "a pinned file has no row")
  assert(vim.api.nvim_win_get_height(panel.win) == tall + 1, "the panel did not grow with the pin")

  -- ── clicking one ──────────────────────────────────────────────────────
  local file_row = assert(line_with("notes.txt"), "the pinned file has no row")
  vim.api.nvim_set_current_win(panel.win)
  vim.api.nvim_win_set_cursor(panel.win, { file_row, 0 })
  vim.fn.maparg("<CR>", "n", false, true).callback()
  wait_for(function()
    local editor = ActivityBar.editor_window()
    return editor
      and vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(editor)):find("notes.txt", 1, true) ~= nil
  end, "opening a pinned file did not open it in the editor")

  -- The heading folds the list away and back.
  vim.api.nvim_set_current_win(panel.win)
  vim.api.nvim_win_set_cursor(panel.win, { 1, 0 })
  vim.fn.maparg("<CR>", "n", false, true).callback()
  assert(#lines() == 1, "collapsing the panel left its rows on screen")
  assert(lines()[1]:find("▸", 1, true), "a collapsed panel is not drawn as collapsed")
  assert(vim.api.nvim_win_get_height(panel.win) == 1, "a collapsed panel still takes the room of an open one")
  vim.fn.maparg("<CR>", "n", false, true).callback()
  assert(#lines() > 1, "expanding the panel did not bring its rows back")

  -- ── a directory takes you there ───────────────────────────────────────
  -- Inside the project the tree opens where it stands. Outside it -- the
  -- mirror the downloads land in -- a tree rooted at the project cannot show
  -- the path at all, so it becomes the root, and the row that appears above
  -- the pins is the way back.
  local picker = assert(ActivityBar.current().content.picker, "the Explorer has no picker")
  Pinned.add(root, outside .. "/mirror")
  local mirror_row = assert(line_with("mirror"), "the outside directory has no row")
  vim.api.nvim_set_current_win(panel.win)
  vim.api.nvim_win_set_cursor(panel.win, { mirror_row, 0 })
  vim.fn.maparg("<CR>", "n", false, true).callback()
  wait_for(function()
    return vim.fs.normalize(picker:cwd()) == vim.fs.normalize(outside .. "/mirror")
  end, "a pinned directory outside the project did not become the tree's root")

  local home_row = assert(line_with(vim.fs.basename(root)), "the panel offers no way back to the project")
  assert(home_row < mirror_row, "the way back is not above the pins")
  vim.api.nvim_set_current_win(panel.win)
  vim.api.nvim_win_set_cursor(panel.win, { home_row, 0 })
  vim.fn.maparg("<CR>", "n", false, true).callback()
  wait_for(function()
    return vim.fs.normalize(picker:cwd()) == vim.fs.normalize(root)
  end, "the way back did not put the tree back on the project")
  assert(not line_with(vim.fs.basename(root)), "the way back is still offered once it is not needed")
  Pinned.remove(root, outside .. "/mirror")

  -- ── it belongs to the Explorer view ───────────────────────────────────
  ActivityBar.open("git", { focus = false })
  wait_for(function()
    return Pinned._panel() == nil
  end, "the pinned panel outlived the Explorer view")
  ActivityBar.open("explorer", { focus = false })
  wait_for(function()
    return Pinned._panel() ~= nil
  end, "the pinned panel did not come back with the Explorer")
  assert(line_with("drivers"), "the pins did not come back with the panel")

  -- ── right-clicking a pin ──────────────────────────────────────────────
  -- The view was closed and opened again above, so this is a new panel.
  panel = assert(Pinned._panel(), "the panel is gone")
  local ContextMenu = require("config.context_menu")
  local row = assert(line_with("drivers"), "the pinned directory has no row")
  vim.api.nvim_set_current_win(panel.win)
  local real_getmousepos = vim.fn.getmousepos
  vim.fn.getmousepos = function()
    return { winid = panel.win, line = row, column = 1, screenrow = row, screencol = 1, winrow = row, wincol = 1 }
  end
  local ok_menu, err_menu = pcall(function()
    vim.fn.maparg("<RightRelease>", "n", false, true).callback()
  end)
  vim.fn.getmousepos = real_getmousepos
  assert(ok_menu, "right-clicking a pin errored: " .. tostring(err_menu))
  assert(vim.bo.filetype == "pinned_context_menu", "right-clicking a pin opened no menu")
  local menu_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  assert(
    vim.iter(menu_lines):any(function(text)
      return text:find("Unpin", 1, true) ~= nil
    end),
    "the menu on a pin does not offer to remove it"
  )
  ContextMenu.close()

  -- ── and the file tree's own menu pins ─────────────────────────────────
  picker = assert(ActivityBar.current().content.picker, "the Explorer has no picker")
  local function label_for(paths)
    for _, entry in ipairs(Menu._entries_for({ picker = picker, item = {}, paths = paths, target_dir = root })) do
      if entry.label == "Pin" or entry.label == "Unpin" or entry.label == "Pin These" or entry.label == "Unpin These" then
        return entry.label
      end
    end
  end
  assert(label_for({ root .. "/drivers" }) == "Unpin", "the menu offers to pin a path that is already pinned")
  assert(label_for({ root .. "/drivers/main.c" }) == "Pin", "the menu does not offer to pin an unpinned path")
  assert(
    label_for({ root .. "/drivers/main.c", root .. "/notes.txt" }) == "Pin These",
    "the menu does not say it acts on the whole selection"
  )
end)

pcall(ActivityBar.close)
pcall(Pinned.detach)
Pinned.setup()
vim.o.columns = original_columns
vim.cmd.cd(vim.fn.fnameescape(original_cwd))
vim.fn.delete(root, "rf")
vim.fn.delete(outside, "rf")
assert(ok, test_error)

print("pinned-ok")
