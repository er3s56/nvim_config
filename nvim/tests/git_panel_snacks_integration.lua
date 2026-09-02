local ContextMenu = require("config.context_menu")

local GitPanel = require("config.git_panel")

-- Each branch keeps its own history now, and the checked-out one is the
-- section that opens itself.
local function current_commits(state)
  local list = state and state.branch and (state.commit_lists or {})[state.branch]
  return list and list.commits or nil
end

assert(rawget(_G, "Snacks") and Snacks.picker, "Snacks must be loaded by the real config")
local bufferline_config = require("bufferline.config").get()
assert(bufferline_config, "Bufferline must be loaded by the real config")
assert(bufferline_config.options.always_show_bufferline == true, "Bufferline hides the final buffer tab")

local root = vim.fn.tempname()
local relative = "src/deep/file.txt"
local file = vim.fs.joinpath(root, relative)
vim.fn.mkdir(vim.fs.dirname(file), "p")
assert(vim.fn.writefile({ "before" }, file) == 0)

local function git(args)
  local command = { "git", "-C", root }
  vim.list_extend(command, args)
  local result = vim.system(command, { text = true }):wait()
  assert(result.code == 0, result.stderr)
end

local function normalized_layout(node, replaced_win, label)
  if node[1] == "leaf" then
    return { "leaf", node[2] == replaced_win and label or node[2] }
  end
  local normalized = { node[1], {} }
  for _, child in ipairs(node[2]) do
    normalized[2][#normalized[2] + 1] = normalized_layout(child, replaced_win, label)
  end
  return normalized
end

local function window_geometry(replaced_win, label)
  local geometry = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(win).relative == "" then
      local position = vim.api.nvim_win_get_position(win)
      geometry[win == replaced_win and label or win] = {
        row = position[1],
        col = position[2],
        width = vim.api.nvim_win_get_width(win),
        height = vim.api.nvim_win_get_height(win),
      }
    end
  end
  return geometry
end

git({ "init", "-q" })
git({ "config", "user.name", "Git Panel Test" })
git({ "config", "user.email", "git-panel@example.invalid" })
git({ "add", relative })
git({ "commit", "-qm", "initial" })
assert(vim.fn.writefile({ "after" }, file) == 0)

vim.cmd.edit(vim.fn.fnameescape(file))
local picker
local state
local ok, test_error = pcall(function()
  picker = Snacks.explorer({
    cwd = root,
    watch = false,
    follow_file = false,
    diagnostics = false,
    git_status = false,
  })
  assert(picker, "Snacks Explorer did not open")
  assert(
    vim.wait(3000, function()
      return picker.list and picker.list.win and picker.list.win:valid()
    end),
    "Snacks Explorer layout did not become ready"
  )

  state = GitPanel.open(picker, root)
  assert(state, "Git panel did not open")
  assert(
    vim.wait(3000, function()
      return state.changes ~= nil and current_commits(state) ~= nil
    end),
    "Git panel did not finish loading"
  )

  local row, entry
  for line, candidate in pairs(state.entries) do
    if candidate.kind == "worktree_file" and candidate.path == relative then
      row, entry = line, candidate
      break
    end
  end
  assert(row and entry, "modified workspace file was not rendered")
  assert(
    vim.api.nvim_buf_get_lines(state.buf, row - 1, row, false)[1]:find(relative, 1, true),
    "Git row hid path segments"
  )

  vim.api.nvim_set_current_win(state.win)
  vim.api.nvim_win_set_cursor(state.win, { row, 0 })
  for _, key in ipairs({ "<CR>", "<LeftMouse>", "<2-LeftMouse>" }) do
    local mapping = vim.fn.maparg(key, "n", false, true)
    assert(type(mapping.callback) == "function", key .. " Git diff mapping is missing")
  end

  vim.cmd.redraw()
  local position = vim.fn.screenpos(state.win, row, 1)
  local mouse = {
    winid = state.win,
    line = row,
    screenrow = position.row,
    screencol = position.col,
  }
  assert(ContextMenu._handlers.git_panel(mouse), "Git file right click was not handled")
  assert(
    vim.wait(1000, function()
      return vim.bo.filetype == "git_panel_context_menu"
    end),
    "Git file context menu did not open"
  )
  assert(vim.api.nvim_win_get_cursor(state.win)[1] == row, "Git right click did not position the panel cursor")
  local menu = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  for _, label in ipairs({ "Open Changes", "Open File", "Stage Changes", "Discard Changes" }) do
    assert(menu:find(label, 1, true), ("the Git menu is missing `%s`"):format(label))
  end
  ContextMenu.close()

  vim.api.nvim_set_current_win(state.win)
  vim.api.nvim_win_set_cursor(state.win, { row, 0 })
  vim.fn.maparg("<CR>", "n", false, true).callback()
  assert(
    vim.wait(3000, function()
      return state.preview_layout ~= nil
        and vim.api.nvim_win_is_valid(state.preview_layout.main_win)
        and vim.api.nvim_win_is_valid(state.preview_layout.after_win)
    end),
    "Enter did not open the Git diff layout"
  )

  -- The working-tree side of a diff is the file itself, so its tab is the
  -- file's. The side that is a snapshot of the index keeps the panel's own
  -- name, and that name is not proactively shortened.
  assert(state.preview.after_is_file, "the working-tree side of the diff is not the file")
  local after_name = vim.api.nvim_buf_get_name(state.preview.bufs[2])
  assert(after_name == vim.fs.normalize(file), "the diff's editable side is not the file it describes")
  assert(vim.bo[state.preview.bufs[2]].modifiable, "the working-tree side of the diff cannot be edited")
  local before_name = vim.api.nvim_buf_get_name(state.preview.bufs[1])
  assert(before_name:find("src›deep›file.txt", 1, true), "diff tab label proactively shortened the path")
  local diff_window_count = #vim.api.nvim_tabpage_list_wins(0)
  local preview = state.preview
  local old_after_win = state.preview_layout.after_win
  local diff_layout = normalized_layout(vim.fn.winlayout(), old_after_win, "after")
  local diff_geometry = window_geometry(old_after_win, "after")

  assert(GitPanel._open_workspace_file(state, entry), "context action did not open the workspace file")
  assert(state.preview_layout == nil, "opening the workspace file left the diff layout active")
  assert(
    #vim.api.nvim_tabpage_list_wins(0) == diff_window_count - 1,
    "opening the workspace file did not close one diff window"
  )
  assert(vim.api.nvim_get_current_win() == state.editor_win, "workspace file did not focus the central editor")
  assert(vim.api.nvim_buf_get_name(0) == file, "central editor opened the wrong workspace path")

  -- The working-tree side is the file, so its tab is the file's: asking for
  -- that buffer opens the file, not the diff it happens to be half of.
  GitPanel.open_buffer(preview.bufs[2])
  vim.wait(400)
  assert(state.preview_layout == nil, "opening the file reopened the diff around it")
  assert(vim.api.nvim_buf_get_name(0) == file, "opening the file showed something else")

  -- The diff comes back the way it was opened, and comes back the same shape.
  vim.api.nvim_set_current_win(state.win)
  vim.api.nvim_win_set_cursor(state.win, { row, 0 })
  vim.fn.maparg("<CR>", "n", false, true).callback()
  assert(
    vim.wait(3000, function()
      return state.preview_layout and vim.api.nvim_win_is_valid(state.preview_layout.after_win)
    end),
    "reopening a retained Git preview did not restore the diff layout"
  )
  assert(
    vim.deep_equal(diff_layout, normalized_layout(vim.fn.winlayout(), state.preview_layout.after_win, "after")),
    "reopening a Git preview changed the window tree"
  )
  assert(
    vim.deep_equal(diff_geometry, window_geometry(state.preview_layout.after_win, "after")),
    "reopening a Git preview changed window geometry"
  )
  assert(GitPanel._open_workspace_file(state, entry), "Git preview did not return to the workspace file")

  local old_panel_win = state.win
  local panel_layout = normalized_layout(vim.fn.winlayout(), old_panel_win, "git")
  local panel_geometry = window_geometry(old_panel_win, "git")
  GitPanel.close()
  assert(not vim.api.nvim_win_is_valid(old_panel_win), "Git panel did not close before its restore test")
  state = GitPanel.open(picker, root)
  assert(state, "Git panel did not reopen")
  assert(
    vim.wait(3000, function()
      return state.changes ~= nil and current_commits(state) ~= nil
    end),
    "reopened Git panel did not finish loading"
  )
  assert(
    vim.deep_equal(panel_layout, normalized_layout(vim.fn.winlayout(), state.win, "git")),
    "closing and reopening the Git panel changed the window tree"
  )
  assert(
    vim.deep_equal(panel_geometry, window_geometry(state.win, "git")),
    "closing and reopening the Git panel changed window geometry"
  )
end)

ContextMenu.close()
if state and state.win and vim.api.nvim_win_is_valid(state.win) then
  pcall(GitPanel.close)
end
if picker and not picker.closed then
  picker:close()
end
vim.fn.delete(root, "rf")
assert(ok, test_error)

print("git-panel-snacks-integration-ok")
