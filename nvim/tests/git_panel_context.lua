local GitPanel = require("config.git_panel")

local function assert_equal(expected, actual, message)
  if not vim.deep_equal(expected, actual) then
    error(("%s\nexpected: %s\nactual:   %s"):format(message, vim.inspect(expected), vim.inspect(actual)))
  end
end

local short_path = "src/config/file.lua"
assert_equal(short_path, GitPanel._display_path(short_path, 40), "short Git path was changed")

local filename = "完整文件名.lua"
local long_path = "非常长的工程/子目录/更深的目录/" .. filename
local shortened = GitPanel._display_path(long_path, 28)
assert(shortened:sub(1, #"…") == "…", "long Git path was not elided from the left")
assert(shortened:sub(-#filename) == filename, "left elision did not preserve the complete filename")
assert(vim.fn.strdisplaywidth(shortened) <= 28, "display-width elision overflowed the panel")

local narrow = GitPanel._display_path("路径/超长的中文文件名.lua", 12)
assert(narrow:sub(1, #"…") == "…", "narrow Unicode path is missing its ellipsis")
assert(vim.fn.strdisplaywidth(narrow) <= 12, "narrow Unicode path overflowed its display width")

local panel_buf = vim.api.nvim_create_buf(false, true)
local panel_win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(panel_win, panel_buf)
local commit_hash = string.rep("a", 40)
local render_state = {
  buf = panel_buf,
  win = panel_win,
  branch = "test",
  changes = { { kind = "worktree_file", status = " M", path = short_path } },
  commits = { { kind = "commit", full_hash = commit_hash, hash = "aaaaaaa", subject = "subject" } },
  collapsed = { changes = false, commits = false },
  expanded = { [commit_hash] = true },
  commit_files = {
    [commit_hash] = {
      files = { { kind = "commit_file", status = "M", path = "lua/config/module.lua" } },
    },
  },
}
GitPanel._render(render_state)
local rendered = vim.api.nvim_buf_get_lines(panel_buf, 0, -1, false)
assert(rendered[5]:find(short_path, 1, true), "CHANGES path was proactively abbreviated")
assert(rendered[9]:find("lua/config/module.lua", 1, true), "expanded commit path was proactively abbreviated")

local root = vim.fn.tempname()
local renamed_path = "new/location/file.txt"
local absolute = vim.fs.joinpath(root, renamed_path)
vim.fn.mkdir(vim.fs.dirname(absolute), "p")
assert(vim.fn.writefile({ "workspace" }, absolute) == 0)

local renamed = {
  kind = "worktree_file",
  status = "R ",
  old_path = "old/location/file.txt",
  path = renamed_path,
}
local state = { root = root, buf = panel_buf, win = panel_win, entries = {} }
assert_equal(absolute, GitPanel._workspace_path(state, renamed), "renamed entry did not resolve its new path")
assert(GitPanel._workspace_context_entries(state, renamed)[1].enabled, "existing workspace file was disabled")

local historical = { kind = "commit_file", status = "M", path = renamed_path }
assert(
  GitPanel._workspace_context_entries(state, historical)[1].enabled,
  "historical entry with a current workspace file was disabled"
)
local deleted = { kind = "worktree_file", status = "D ", path = "removed.txt" }
assert(not GitPanel._workspace_context_entries(state, deleted)[1].enabled, "deleted workspace file was enabled")

vim.bo[panel_buf].modifiable = true
vim.api.nvim_buf_set_lines(panel_buf, 0, -1, false, { "file", "section", "commit", "padding" })
vim.bo[panel_buf].modifiable = false
state.entries = {
  [1] = renamed,
  [2] = { kind = "section" },
  [3] = { kind = "commit" },
}
local function mouse_for_line(line)
  local position = vim.fn.screenpos(panel_win, line, 1)
  return { winid = panel_win, line = line, screenrow = position.row, screencol = position.col }
end
assert_equal(renamed, GitPanel._context_entry_at_mouse(state, mouse_for_line(1)), "Git file row was not hit")
assert_equal(nil, GitPanel._context_entry_at_mouse(state, mouse_for_line(2)), "Git section opened a file menu")
assert_equal(nil, GitPanel._context_entry_at_mouse(state, mouse_for_line(3)), "Git commit opened a file menu")
local padding_mouse = mouse_for_line(4)
padding_mouse.screenrow = padding_mouse.screenrow + 1
assert_equal(nil, GitPanel._context_entry_at_mouse(state, padding_mouse), "Git panel padding opened a file menu")

local original_open_buffer = GitPanel.open_buffer
local original_notify = vim.notify
local opened = {}
GitPanel.open_buffer = function(buf)
  opened[#opened + 1] = buf
end
vim.notify = function() end

local ok, test_error = pcall(function()
  local menu_entry = GitPanel._workspace_context_entries(state, renamed)[1]
  assert(menu_entry.enabled, "existing file was disabled before the race test")
  assert(vim.fn.delete(absolute) == 0)
  menu_entry.action()
  assert_equal(0, #opened, "file removed after menu creation was still opened")

  assert(vim.fn.writefile({ "workspace" }, absolute) == 0)
  assert(GitPanel._open_workspace_file(state, renamed), "existing workspace file did not open")
  assert_equal(1, #opened, "workspace file did not use GitPanel.open_buffer")
  assert_equal(absolute, vim.api.nvim_buf_get_name(opened[1]), "workspace buffer used the wrong path")
end)

GitPanel.open_buffer = original_open_buffer
vim.notify = original_notify
vim.fn.delete(root, "rf")
assert(ok, test_error)

print("git-panel-context-ok")
