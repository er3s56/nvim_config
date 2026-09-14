-- The functions behind the editor-style keys in config/keymaps.lua. The keys
-- themselves are not loaded here (keymaps load on VeryLazy); what they call
-- is exercised directly.
local ActivityBar = require("config.activity_bar")
local GitPanel = require("config.git_panel")
local TerminalTabs = require("config.terminal_tabs")

assert(vim.fn.executable("rg") == 1, "the Search sidebar needs ripgrep")

local root = vim.fs.normalize(vim.fn.tempname())
vim.fn.mkdir(root, "p")
assert(vim.fn.writefile({ "needle here", "other there" }, vim.fs.joinpath(root, "a.txt")) == 0)
assert(vim.system({ "git", "-C", root, "init", "-q" }):wait().code == 0)

local function wait(ms, condition, message)
  assert(vim.wait(ms, condition), message)
end

local function search_picker()
  local state = ActivityBar.current()
  local picker = state and state.content and state.content.kind == "search" and state.content.picker or nil
  return picker and not picker.closed and picker or nil
end

local function search_settled(query, count)
  return function()
    local picker = search_picker()
    return picker ~= nil
      and picker.input.filter.search == query
      and not picker:is_active()
      and picker.list:count() == count
  end
end

local function terminal_group()
  return TerminalTabs._groups[TerminalTabs._normalize_root(root)]
end

local function terminal_focused()
  local group = terminal_group()
  return group ~= nil
    and group.visible == true
    and group.active ~= nil
    and group.active.terminal:win_valid()
    and TerminalTabs.owns_window(vim.api.nvim_get_current_win())
end

local original_cwd = vim.fn.getcwd(0)
local ok, test_error = pcall(function()
  vim.cmd.cd(vim.fn.fnameescape(root))
  assert(vim.fs.normalize(LazyVim.root()) == root, "the project root is not the temp repo: " .. LazyVim.root())
  ActivityBar.setup()

  -- Ctrl+Shift+F with a selection: the sidebar comes up searching for it,
  -- with the focus in its box, even before any sidebar exists.
  local state = assert(ActivityBar.search("needle"), "search() did not open a sidebar")
  wait(5000, search_settled("needle", 1), "search(query) did not find the line")
  assert(state.view == "search", "search() did not switch the sidebar to Search")
  local first = assert(search_picker())
  assert(vim.api.nvim_get_current_win() == first.input.win.win, "search() did not focus the box")
  local editor = assert(ActivityBar.editor_window())

  -- Again while it is up: the same picker, told the new query.
  ActivityBar.search("other")
  wait(5000, search_settled("other", 1), "search(query) on an open sidebar did not change the query")
  assert(search_picker() == first, "search(query) rebuilt a sidebar that was already up")

  -- Ctrl+B hides the sidebar and brings it back as it was, without taking
  -- the focus.
  vim.api.nvim_set_current_win(editor)
  ActivityBar.toggle(state.view, { focus = false })
  wait(3000, function()
    return state.collapsed == true
  end, "toggling the sidebar did not collapse it")
  assert(vim.api.nvim_get_current_win() == editor, "collapsing the sidebar moved the focus")
  ActivityBar.toggle(state.view, { focus = false })
  wait(5000, search_settled("other", 1), "toggling the sidebar back did not restore Search with its query")
  assert(state.view == "search", "toggling the sidebar back switched to another view")
  assert(vim.api.nvim_get_current_win() == editor, "expanding the sidebar moved the focus")

  -- Ctrl+B from inside the sidebar hides it too, and hands the focus back.
  -- Snacks would have the key scroll a preview.
  local current = assert(search_picker())
  vim.api.nvim_set_current_win(current.input.win.win)
  local inside = vim.api.nvim_buf_call(current.input.win.buf, function()
    return vim.fn.maparg("<C-b>", "i", false, true)
  end)
  assert(inside.desc == "Hide the sidebar", "Ctrl+B inside the sidebar is not the sidebar's own")
  inside.callback()
  wait(3000, function()
    return state.collapsed == true
  end, "Ctrl+B from inside the sidebar did not hide it")
  wait(3000, function()
    return vim.api.nvim_get_current_win() == editor
  end, "hiding the sidebar from inside did not return the focus to the editor")
  ActivityBar.toggle(state.view, { focus = false })
  wait(5000, search_settled("other", 1), "the sidebar did not come back after Ctrl+B from inside")

  -- Ctrl+` from the sidebar box brings the terminal up; from the terminal it
  -- brought up, puts it away -- whatever the project root looks like from
  -- the box, which is a scratch buffer.
  vim.api.nvim_set_current_win(search_picker().input.win.win)
  GitPanel.toggle_terminal()
  wait(5000, terminal_focused, "the terminal did not come up from the sidebar box")
  GitPanel.toggle_terminal()
  wait(3000, function()
    return terminal_group() ~= nil and terminal_group().visible == false
  end, "toggling from the terminal opened from the sidebar did not hide it")

  -- Ctrl+` from the editor: up and focused; pressed again from inside, away;
  -- pressed from the editor while it is up but unfocused, focused rather
  -- than hidden.
  vim.api.nvim_set_current_win(editor)
  GitPanel.toggle_terminal()
  wait(5000, terminal_focused, "the first toggle did not bring the terminal up and focus it")
  GitPanel.toggle_terminal()
  wait(3000, function()
    return terminal_group().visible == false
  end, "toggling from inside the terminal did not hide it")
  vim.api.nvim_set_current_win(editor)
  GitPanel.toggle_terminal()
  wait(5000, terminal_focused, "the terminal did not come back focused")
  vim.api.nvim_set_current_win(editor)
  GitPanel.toggle_terminal()
  wait(3000, terminal_focused, "toggling from the editor did not focus the visible terminal")
  assert(terminal_group().visible == true, "toggling from the editor hid the terminal instead of focusing it")
end)

vim.cmd.cd(vim.fn.fnameescape(original_cwd))
if not ok then
  io.stderr:write("FAIL: " .. tostring(test_error) .. "\n")
  os.exit(1)
end
print("vscode_keys: all checks passed")
os.exit(0)
