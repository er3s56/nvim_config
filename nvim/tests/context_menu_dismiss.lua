local ActivityBar = require("config.activity_bar")
local ContextMenu = require("config.context_menu")
local GitPanel = require("config.git_panel")

local root = vim.fn.tempname()
local relative = "src/file.txt"
local file = vim.fs.joinpath(root, relative)
vim.fn.mkdir(vim.fs.dirname(file), "p")
assert(vim.fn.writefile({ "one", "two" }, file) == 0)

local function git(args)
  local command = { "git", "-C", root }
  vim.list_extend(command, args)
  local result = vim.system(command, { text = true }):wait()
  assert(result.code == 0, table.concat(args, " ") .. ": " .. (result.stderr or ""))
end

git({ "init", "-q" })
git({ "config", "user.name", "Context Menu Test" })
git({ "config", "user.email", "context-menu@example.invalid" })
git({ "add", relative })
git({ "commit", "-qm", "initial" })
assert(vim.fn.writefile({ "ONE", "two" }, file) == 0)

local original_cwd = vim.fn.getcwd(0)
local original_columns = vim.o.columns
local original_mousemove = vim.o.mousemoveevent
local original_getmousepos = vim.fn.getmousepos

local function menu_window()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype:find("context_menu") then
      return win
    end
  end
end

local function wait_for(condition, message)
  assert(vim.wait(5000, condition, 20), message)
end

-- The press has to be resolved the way Neovim resolves it, not by calling the
-- module directly: the whole point is that a panel's own global mapping is
-- what receives it.
local function global_mapping(lhs)
  for _, map in ipairs(vim.api.nvim_get_keymap("n")) do
    if map.lhs == lhs and map.callback then
      return map.callback
    end
  end
end

local function buffer_mapping(buf, lhs)
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    if map.lhs == lhs and map.callback then
      return map.callback
    end
  end
end

local function press(callback, mouse)
  vim.fn.getmousepos = function()
    return mouse
  end
  local ok, produced = pcall(callback)
  vim.fn.getmousepos = original_getmousepos
  assert(ok, "the mouse handler errored: " .. tostring(produced))
  return produced
end

local function mouse_over(win, line)
  local position = vim.fn.screenpos(win, line, 1)
  return {
    winid = win,
    line = line,
    column = 3,
    screenrow = position.row,
    screencol = position.col,
    winrow = line,
    wincol = 3,
  }
end

local ok, test_error = pcall(function()
  vim.cmd.cd(vim.fn.fnameescape(root))
  vim.cmd.edit(vim.fn.fnameescape(file))
  vim.o.columns = 160
  ActivityBar.setup()

  -- ── the Explorer, whose presses the Activity Bar answers ──────────────
  -- Done before the Git panel exists: the Git panel installs a global
  -- <LeftMouse> of its own that shadows the Activity Bar's from then on, and
  -- both have to consult the menu.
  local explorer_view = ActivityBar.open("explorer", { focus = false })
  wait_for(function()
    local picker = explorer_view.content and explorer_view.content.picker
    return picker and picker.list and picker.list.win and picker.list.win:valid() and picker.list:count() > 0
  end, "the Explorer did not open")
  local list_win = explorer_view.content.picker.list.win.win

  assert(ContextMenu._handlers.explorer(mouse_over(list_win, 1)), "the Explorer did not offer a menu")
  wait_for(menu_window, "the Explorer menu never opened")
  local menu_win = menu_window()

  -- A press on the menu itself is the menu's own business.
  assert(ContextMenu.dismiss(mouse_over(menu_win, 1)) == false, "a press on the menu dismissed it")
  vim.wait(100)
  assert(menu_window(), "a press on the menu closed it")

  -- A press on the Explorer is swallowed by the Activity Bar's own handler, so
  -- that handler is the one that has to close the menu.
  local activity_click = assert(global_mapping("<LeftMouse>"), "no global <LeftMouse> mapping")
  local before = explorer_view.content.picker.list:count()
  assert(press(activity_click, mouse_over(list_win, 2)) == "", "the dismissing press was passed through")
  wait_for(function()
    return menu_window() == nil
  end, "a press on the Explorer left the menu open")
  vim.wait(200)
  assert(explorer_view.content.picker.list:count() == before, "the dismissing press also acted on the Explorer")

  -- ── the Git panel, whose global mapping shadows it ────────────────────
  local view = ActivityBar.open("git", { focus = false })
  wait_for(function()
    return view.content and view.content.kind == "git" and view.content.git_state
  end, "the Git panel did not open")
  local panel = view.content.git_state
  GitPanel.refresh(panel.buf, { status_only = true })

  local row
  wait_for(function()
    for line, entry in pairs(panel.entries or {}) do
      if entry.kind == "worktree_file" then
        row = line
        return true
      end
    end
  end, "the change never appeared in the panel")

  local function open_menu()
    assert(ContextMenu._handlers.git_panel(mouse_over(panel.win, row)), "the panel did not offer a menu")
    wait_for(menu_window, "the panel menu never opened")
  end

  open_menu()
  local panel_click = assert(global_mapping("<LeftMouse>"), "no global <LeftMouse> mapping")
  assert(press(panel_click, mouse_over(panel.win, row + 1)) == "", "the dismissing press was passed through")
  wait_for(function()
    return menu_window() == nil
  end, "a press on the Git panel left the menu open")
  vim.wait(200)
  assert(panel.preview == nil, "the dismissing press also opened a diff")

  -- The panel's buffer-local mapping shadows the global one whenever the panel
  -- itself has focus, so it has to ask as well.
  open_menu()
  local buffer_click = assert(buffer_mapping(panel.buf, "<LeftMouse>"), "the panel has no buffer-local <LeftMouse>")
  assert(press(buffer_click, mouse_over(panel.win, row)) == "", "the dismissing press was passed through")
  wait_for(function()
    return menu_window() == nil
  end, "the panel's own mapping left the menu open")

  -- Whatever else moves focus closes it too, including anything that never
  -- goes through a mouse mapping at all.
  open_menu()
  local editor = assert(ActivityBar.editor_window(), "the tab has no editor window")
  vim.api.nvim_set_current_win(editor)
  wait_for(function()
    return menu_window() == nil
  end, "the menu survived losing focus")

  -- ── a press on a row that cannot be chosen ────────────────────────────
  -- Half a menu can be greyed out, and one that silently ignores presses is
  -- indistinguishable from one that cannot be dismissed at all.
  open_menu()
  local menu = assert(menu_window())
  local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(menu), 0, -1, false)
  local disabled, separator, enabled
  for index, text in ipairs(lines) do
    if text:find("Unstage Changes", 1, true) then
      disabled = index
    elseif text:find("─", 1, true) then
      separator = index
    elseif text:find("Stage Changes", 1, true) then
      enabled = index
    end
  end
  assert(disabled and separator and enabled, "the menu is not the shape this test needs")

  local menu_click = assert(buffer_mapping(vim.api.nvim_win_get_buf(menu), "<LeftMouse>"), "the menu has no click")
  assert(press(menu_click, mouse_over(menu, disabled)) == "", "the press was passed through")
  wait_for(function()
    return menu_window() == nil
  end, "a press on a greyed entry left the menu open")

  open_menu()
  menu = assert(menu_window())
  menu_click = assert(buffer_mapping(vim.api.nvim_win_get_buf(menu), "<LeftMouse>"))
  press(menu_click, mouse_over(menu, separator))
  wait_for(function()
    return menu_window() == nil
  end, "a press on a separator left the menu open")

  -- A row that can be chosen still is.
  local before_status = panel.changes[1].status
  open_menu()
  menu = assert(menu_window())
  menu_click = assert(buffer_mapping(vim.api.nvim_win_get_buf(menu), "<LeftMouse>"))
  press(menu_click, mouse_over(menu, enabled))
  wait_for(function()
    return menu_window() == nil
  end, "a press on an enabled entry left the menu open")
  wait_for(function()
    return (panel.changes[1] or {}).status ~= before_status
  end, "a press on `Stage Changes` closed the menu without staging anything")

  -- A right click somewhere else replaces the menu instead of stacking one on
  -- top of it.
  open_menu()
  local first = menu_window()
  assert(ContextMenu._handlers.git_panel(mouse_over(panel.win, row)), "the panel did not offer a second menu")
  wait_for(function()
    local current = menu_window()
    return current ~= nil and current ~= first
  end, "a second right click did not replace the menu")
  local count = 0
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype:find("context_menu") then
      count = count + 1
    end
  end
  assert(count == 1, ("%d menus are open at once"):format(count))
  ContextMenu.close()
end)

vim.fn.getmousepos = original_getmousepos
pcall(ContextMenu.close)
pcall(ActivityBar.close)
pcall(GitPanel.close)
vim.o.columns = original_columns
vim.o.mousemoveevent = original_mousemove
vim.cmd.cd(vim.fn.fnameescape(original_cwd))
vim.fn.delete(root, "rf")
assert(ok, test_error)

print("context-menu-dismiss-ok")
