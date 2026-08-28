local ActivityBar = require("config.activity_bar")
local GitPanel = require("config.git_panel")
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
git({ "config", "user.name", "Git Panel Test" })
git({ "config", "user.email", "git-panel@example.invalid" })
git({ "add", relative })
git({ "commit", "-qm", "initial" })

local original_cwd = vim.fn.getcwd(0)

local function open_git()
  local state = ActivityBar.open("git", { focus = false })
  assert(
    vim.wait(5000, function()
      return state.content
        and state.content.kind == "git"
        and state.content.git_state
        and state.content.git_state.changes ~= nil
    end),
    "the Git panel did not become ready"
  )
  return state.content.git_state
end

local function change_count(panel)
  return #(panel.changes or {})
end

local ok, test_error = pcall(function()
  vim.cmd.cd(vim.fn.fnameescape(root))
  vim.cmd.edit(vim.fn.fnameescape(file))
  ActivityBar.setup()

  -- Mirror the real layout: the Explorer and the terminal come up first.
  ActivityBar.open("explorer", { focus = false })
  TerminalTabs.open(root, false)
  assert(
    vim.wait(5000, function()
      local group = TerminalTabs._groups[TerminalTabs._normalize_root(root)]
      return group and group.active and group.active.terminal:win_valid()
    end),
    "the project terminal did not become ready"
  )

  local panel = open_git()
  assert(change_count(panel) == 0, "the test repository did not start clean")

  -- The Git directory watcher is what covers Git commands run outside Neovim.
  assert(
    vim.wait(5000, function()
      return panel.git_watcher ~= nil
    end),
    "the Git panel never started its Git directory watcher"
  )
  assert(not panel.git_watcher:is_closing(), "the Git directory watcher is not running")

  -- A file created straight on disk bypasses BufWritePost, exactly like one
  -- created outside Neovim. Deliberately use a path no buffer holds and Git
  -- does not track: an open buffer would be caught by Gitsigns instead, and
  -- the Git directory watcher never sees working-tree changes at all, so
  -- returning to Neovim is the only thing that can reveal this one.
  local untracked = vim.fs.joinpath(root, "src/untracked.txt")
  assert(vim.fn.writefile({ "new" }, untracked) == 0)
  vim.api.nvim_exec_autocmds("FocusGained", {})
  assert(
    vim.wait(5000, function()
      return change_count(panel) == 1
    end),
    "FocusGained did not pick up a file created outside Neovim"
  )

  -- Then a tracked file edited on disk, which is what the user actually hits.
  assert(vim.fn.writefile({ "after" }, file) == 0)
  vim.api.nvim_exec_autocmds("FocusGained", {})
  assert(
    vim.wait(5000, function()
      return change_count(panel) == 2
    end),
    "FocusGained did not pick up a tracked file changed outside Neovim"
  )
  assert(vim.fn.delete(untracked) == 0, "could not remove the temporary untracked file")

  -- Committing moves HEAD, so the watcher has to reload the commit list too,
  -- not just the status.
  local before = #(panel.commits or {})
  git({ "add", "-A" })
  git({ "commit", "-qm", "second" })
  assert(
    vim.wait(10000, function()
      return #(panel.commits or {}) == before + 1 and change_count(panel) == 0
    end),
    ("the Git directory watcher did not reload after a commit (commits=%d changes=%d)"):format(
      #(panel.commits or {}),
      change_count(panel)
    )
  )

  -- Activity Bar rebuilds the panel on every view switch, so a watcher that
  -- outlived its panel would leak a file handle per switch. Tear down through
  -- Activity Bar rather than GitPanel.detach(), which is only half of a view
  -- switch and leaves Activity Bar still holding the detached panel.
  local function close_git()
    ActivityBar.open("explorer", { focus = false })
    assert(
      vim.wait(5000, function()
        return GitPanel.current() == nil
      end),
      "the Git panel did not close"
    )
  end

  local seen = { panel.git_watcher }
  close_git()
  for _ = 1, 3 do
    local reopened = open_git()
    -- The watcher starts once `git rev-parse` has resolved the Git directory.
    assert(
      vim.wait(5000, function()
        return reopened.git_watcher ~= nil
      end),
      "a reopened Git panel never started a watcher"
    )
    seen[#seen + 1] = reopened.git_watcher
    close_git()
  end
  for index, handle in ipairs(seen) do
    assert(handle:is_closing(), ("watcher %d was left open after its panel closed"):format(index))
  end
end)

pcall(ActivityBar.close)
pcall(TerminalTabs.close_all, root)
vim.cmd.cd(vim.fn.fnameescape(original_cwd))
vim.fn.delete(root, "rf")
assert(ok, test_error)

print("git-panel-refresh-ok")
