local ActivityBar = require("config.activity_bar")
local GitPanel = require("config.git_panel")

local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local function git(args)
  local command = { "git", "-C", root }
  vim.list_extend(command, args)
  local result = vim.system(command, { text = true }):wait()
  assert(result.code == 0, result.stderr)
end
git({ "init", "-q" })
git({ "config", "user.name", "t" })
git({ "config", "user.email", "t@example.invalid" })
-- More than one batch of history so the growth can actually be observed.
for index = 1, 260 do
  assert(vim.fn.writefile({ tostring(index) }, root .. "/f.txt") == 0)
  git({ "add", "-A" })
  git({ "commit", "-qm", "commit " .. index })
end

local original_cwd = vim.fn.getcwd(0)
local original_columns = vim.o.columns

local function panel()
  return assert(GitPanel.current(), "no Git panel")
end

-- Every branch keeps its own history; this repository has one, and it is the
-- section that opens itself.
local function list()
  local state = GitPanel.current()
  return state and state.branch and (state.commit_lists or {})[state.branch] or nil
end

local function loaded()
  local current = list()
  return current and current.commits and #current.commits or 0
end

local function exhausted()
  local current = list()
  return current ~= nil and current.exhausted == true
end

-- `normal! G` inside nvim_win_call does not move the viewport of a window
-- that is not focused, so drive the view directly.
-- The Load More entry lives in the sparse `entries` table, keyed by buffer
-- line, so it has to be scanned by line number rather than with ipairs.
local function load_more_line()
  local state = panel()
  for line = 1, vim.api.nvim_buf_line_count(state.buf) do
    local entry = state.entries[line]
    if entry and entry.kind == "commit_load_more" then
      return line, entry
    end
  end
end

local function activate_load_more()
  local line = assert(load_more_line(), "no Load More entry to activate")
  local state = panel()
  vim.api.nvim_set_current_win(state.win)
  vim.api.nvim_win_set_cursor(state.win, { line, 0 })
  vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
end

local ok, test_error = pcall(function()
  vim.cmd.cd(vim.fn.fnameescape(root))
  vim.o.columns = 160
  ActivityBar.setup()

  local state = ActivityBar.open("git", { focus = false })
  assert(
    vim.wait(10000, function()
      return state.content and state.content.kind == "git" and loaded() > 0
    end),
    "the Git panel never loaded any commits"
  )

  -- The whole history is not fetched up front: `git log` over a large
  -- repository was measured at 11s and 110MB of output, and the panel would
  -- then hold a line per commit.
  local first = loaded()
  assert(first == 200, ("the first batch loaded %d commits, expected 200"):format(first))
  assert(not exhausted(), "a truncated first batch was marked exhausted")
  assert(load_more_line(), "the truncated list has no Load More entry")

  -- The list stops there. It must not keep growing on its own, whether the
  -- panel is simply left alone or scrolled to the very bottom.
  vim.wait(1500)
  assert(loaded() == first, "the commit list grew without being asked")
  local state = panel()
  vim.api.nvim_win_call(state.win, function()
    vim.cmd("normal! G")
  end)
  vim.wait(1500)
  assert(loaded() == first, "scrolling to the bottom extended the list on its own")

  -- Activating the entry loads the next batch.
  activate_load_more()
  assert(
    vim.wait(10000, function()
      return loaded() > first
    end),
    "activating Load More did not extend the commit list"
  )
  assert(loaded() == 260, ("expected the rest of the history, got %d"):format(loaded()))

  -- With the history exhausted the entry is gone, so there is nothing left to
  -- activate and no further fetching.
  assert(exhausted(), "the end of the history was not detected")
  assert(not load_more_line(), "the Load More entry outlived the end of the history")
  local settled = loaded()
  vim.wait(800)
  assert(loaded() == settled, "the panel kept fetching after the history was exhausted")

  -- Activity Bar destroys and rebuilds the panel on every view switch, so the
  -- expanded depth has to survive as repository state rather than panel state.
  local expanded = loaded()
  local was_exhausted = exhausted()
  ActivityBar.open("explorer", { focus = false })
  assert(
    vim.wait(5000, function()
      return GitPanel.current() == nil
    end),
    "the Git panel did not close"
  )
  ActivityBar.open("git", { focus = false })
  assert(
    vim.wait(10000, function()
      return GitPanel.current() ~= nil and loaded() > 0
    end),
    "the Git panel did not come back"
  )
  vim.wait(500)
  assert(loaded() == expanded, ("switching views reset the commit list from %d to %d"):format(expanded, loaded()))
  assert(
    exhausted() == was_exhausted,
    "switching views lost the end-of-history state, resurrecting a dead Load More entry"
  )
  assert(not load_more_line(), "a Load More entry came back after the history was exhausted")

  -- A refresh (a commit, a checkout) must not yank the list back to the first
  -- batch while it is being read.
  local before_refresh = loaded()
  GitPanel.refresh(panel().buf)
  assert(
    vim.wait(10000, function()
      return loaded() >= before_refresh
    end),
    ("a refresh reset the commit list to %d, losing the scrolled depth of %d"):format(loaded(), before_refresh)
  )
end)

pcall(ActivityBar.close)
vim.o.columns = original_columns
vim.cmd.cd(vim.fn.fnameescape(original_cwd))
vim.fn.delete(root, "rf")
assert(ok, test_error)

print("git-panel-commits-ok")
