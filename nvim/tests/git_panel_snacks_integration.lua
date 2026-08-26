local ContextMenu = require("config.context_menu")
local GitPanel = require("config.git_panel")

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
      return state.changes ~= nil and state.commits ~= nil
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
  assert(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]:find("Open File", 1, true), "Git menu action is missing")
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

  local after_name = vim.api.nvim_buf_get_name(state.preview.bufs[2])
  assert(after_name:find("src›deep›file.txt", 1, true), "diff tab label proactively shortened the path")
  local diff_window_count = #vim.api.nvim_tabpage_list_wins(0)

  assert(GitPanel._open_workspace_file(state, entry), "context action did not open the workspace file")
  assert(state.preview_layout == nil, "opening the workspace file left the diff layout active")
  assert(
    #vim.api.nvim_tabpage_list_wins(0) == diff_window_count - 1,
    "opening the workspace file did not close one diff window"
  )
  assert(vim.api.nvim_get_current_win() == state.editor_win, "workspace file did not focus the central editor")
  assert(vim.api.nvim_buf_get_name(0) == file, "central editor opened the wrong workspace path")
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
