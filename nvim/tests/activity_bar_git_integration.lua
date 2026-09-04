local ActivityBar = require("config.activity_bar")
local TerminalTabs = require("config.terminal_tabs")

local root = vim.fn.tempname()
local relative = "src/file.txt"
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
git({ "config", "user.name", "Activity Bar Test" })
git({ "config", "user.email", "activity-bar@example.invalid" })
git({ "add", relative })
git({ "commit", "-qm", "initial" })
assert(vim.fn.writefile({ "after" }, file) == 0)

local original_cwd = vim.fn.getcwd(0)
local ok, test_error = pcall(function()
  vim.cmd.cd(vim.fn.fnameescape(root))
  vim.cmd.edit(vim.fn.fnameescape(file))
  ActivityBar.setup()

  local state = ActivityBar.open("explorer", { focus = false })
  assert(
    vim.wait(3000, function()
      return state.content and state.content.kind == "explorer" and ActivityBar._content_root(state.content)
    end),
    "Activity Bar Explorer did not become ready"
  )
  TerminalTabs.open(root, false)
  assert(
    vim.wait(3000, function()
      local group = TerminalTabs._groups[TerminalTabs._normalize_root(root)]
      return group and group.active.terminal:win_valid()
    end),
    "Activity Bar test terminal did not become ready"
  )
  ActivityBar.reflow()

  state = ActivityBar.open("git", { focus = false })
  assert(
    vim.wait(3000, function()
      return state.content
        and state.content.kind == "git"
        and state.content.git_state
        and state.content.git_state.changes ~= nil
    end),
    "Activity Bar Git view did not become ready"
  )

  local editor_win = assert(ActivityBar.editor_window())
  local git_state = state.content.git_state
  local ephemeral = vim.api.nvim_create_buf(false, true)
  vim.bo[ephemeral].bufhidden = "wipe"
  vim.bo[ephemeral].filetype = "snacks_dashboard"
  vim.api.nvim_win_set_buf(editor_win, ephemeral)
  local row
  for line, entry in pairs(git_state.entries) do
    if entry.kind == "worktree_file" and entry.path == relative then
      row = line
      break
    end
  end
  assert(row, "modified workspace file was not rendered in Activity Bar Git")

  vim.api.nvim_set_current_win(git_state.win)
  vim.api.nvim_win_set_cursor(git_state.win, { row, 0 })
  local enter = vim.fn.maparg("<CR>", "n", false, true)
  assert(type(enter.callback) == "function", "Activity Bar Git Enter mapping is missing")
  enter.callback()
  assert(
    vim.wait(3000, function()
      return git_state.preview_layout
        and vim.api.nvim_win_is_valid(git_state.preview_layout.main_win)
        and vim.api.nvim_win_is_valid(git_state.preview_layout.after_win)
    end),
    "Activity Bar Git did not open its Diff layout"
  )

  local diff_main = git_state.preview_layout.main_win
  local diff_after = git_state.preview_layout.after_win
  local diff_before = vim.api.nvim_win_get_buf(diff_main)
  local diff_side = vim.api.nvim_win_get_buf(diff_after)
  assert(diff_main == editor_win, "the diff did not take the central editor window")

  ActivityBar.open("explorer")
  assert(
    vim.wait(3000, function()
      return state.content and state.content.kind == "explorer" and ActivityBar._content_root(state.content)
    end),
    "switching away from an active Git Diff did not open Explorer"
  )
  assert(vim.api.nvim_win_is_valid(editor_win), "switching away from Git Diff deleted the central editor")
  assert(ActivityBar.editor_window() == editor_win, "switching away from Git Diff replaced the central editor")
  assert(vim.api.nvim_buf_is_valid(vim.api.nvim_win_get_buf(editor_win)), "Git Diff left no usable editor buffer")
  -- Which panel is showing on the left says nothing about what belongs on the
  -- right. The diff the reader opened is still open, in both of its windows,
  -- still showing what it showed and still comparing them.
  assert(
    vim.api.nvim_win_is_valid(diff_main) and vim.api.nvim_win_is_valid(diff_after),
    "switching panels closed the diff the reader was reading"
  )
  assert(vim.wo[diff_main].diff and vim.wo[diff_after].diff, "switching panels took the diff out of diff mode")
  assert(
    vim.api.nvim_win_get_buf(diff_main) == diff_before and vim.api.nvim_win_get_buf(diff_after) == diff_side,
    "switching panels changed what the diff was showing"
  )

  local sidebar = assert(ActivityBar._content_root(state.content))
  local pinned = assert(require("config.pinned")._panel(), "the Explorer opened without its pinned paths").win
  local active_terminal_group = assert(TerminalTabs._groups[TerminalTabs._normalize_root(root)])
  local terminal_win = active_terminal_group.active.terminal.win
  assert(
    vim.deep_equal(vim.fn.winlayout(), {
      "row",
      {
        { "leaf", state.activity.win },
        { "col", { { "leaf", pinned }, { "leaf", sidebar } } },
        {
          "col",
          {
            { "row", { { "leaf", diff_main }, { "leaf", diff_after } } },
            { "leaf", terminal_win },
          },
        },
      },
    }),
    "switching away from Git Diff corrupted the Activity Bar layout: " .. vim.inspect(vim.fn.winlayout())
  )
end)

pcall(ActivityBar.close)
local terminal_root = TerminalTabs._normalize_root(root)
local terminal_group = TerminalTabs._groups[terminal_root]
if terminal_group then
  for _, item in ipairs(terminal_group.items) do
    item.removing = true
    if item.terminal:buf_valid() then
      pcall(item.terminal.close, item.terminal)
    end
  end
  TerminalTabs._groups[terminal_root] = nil
end
pcall(vim.cmd, "enew")
vim.wait(200)
vim.cmd.cd(vim.fn.fnameescape(original_cwd))
vim.fn.delete(root, "rf")
assert(ok, test_error)

print("activity-bar-git-integration-ok")
