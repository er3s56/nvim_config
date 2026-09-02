local ActivityBar = require("config.activity_bar")
local GitPanel = require("config.git_panel")

local root = vim.fn.tempname()
local remote = vim.fn.tempname()
vim.fn.mkdir(root, "p")

local function git(args, where)
  local command = { "git", "-C", where or root }
  vim.list_extend(command, args)
  local result = vim.system(command, { text = true }):wait()
  assert(result.code == 0, table.concat(args, " ") .. ": " .. (result.stderr or ""))
  return result.stdout or ""
end

local function commit(text, message)
  assert(vim.fn.writefile({ text }, root .. "/f.txt") == 0)
  git({ "add", "-A" })
  git({ "commit", "-qm", message })
end

git({ "init", "-q", "--bare", remote }, vim.fn.fnamemodify(remote, ":h"))
git({ "init", "-q" })
git({ "config", "user.name", "Git Panel Test" })
git({ "config", "user.email", "git-panel@example.invalid" })
commit("one", "first on the trunk")
git({ "remote", "add", "origin", remote })
git({ "push", "-q", "-u", "origin", "HEAD" })

-- A branch of its own, with a commit the trunk does not have.
git({ "checkout", "-q", "-b", "feature" })
commit("feature", "only on feature")
git({ "checkout", "-q", "-" })
-- And one commit past the remote, so the trunk is ahead by one.
commit("two", "second on the trunk")

local original_cwd = vim.fn.getcwd(0)
local original_columns = vim.o.columns
local original_mousemove = vim.o.mousemoveevent

local function wait_for(condition, message)
  assert(vim.wait(5000, condition, 50), message)
end

local function lines(panel)
  return vim.api.nvim_buf_get_lines(panel.buf, 0, -1, false)
end

local function line_matching(panel, needle)
  for index, text in ipairs(lines(panel)) do
    if text:find(needle, 1, true) then
      return index, text
    end
  end
end

local function branch_row(panel, ref)
  for line, entry in pairs(panel.entries or {}) do
    if entry.kind == "branch" and entry.ref == ref then
      return line, entry
    end
  end
end

local ok, test_error = pcall(function()
  vim.cmd.cd(vim.fn.fnameescape(root))
  vim.cmd.edit(vim.fn.fnameescape(root .. "/f.txt"))
  vim.o.columns = 160
  ActivityBar.setup()

  local view = ActivityBar.open("git", { focus = false })
  wait_for(function()
    return view.content and view.content.kind == "git" and view.content.git_state
  end, "the Git panel did not open")
  local panel = view.content.git_state

  wait_for(function()
    return panel.branches ~= nil and #panel.branches == 2
  end, "the panel never listed both branches")
  local trunk = assert(panel.branch, "the panel does not know which branch is checked out")

  -- ── the checked-out branch opens itself, the rest stay shut ───────────
  local current
  for _, branch in ipairs(panel.branches) do
    if branch.current then
      current = branch.ref
    end
  end
  assert(current == trunk, ("`%s` is checked out but `%s` is marked current"):format(trunk, tostring(current)))
  assert(panel.collapsed["branch:" .. trunk] == false, "the checked-out branch did not open itself")
  assert(panel.collapsed["branch:feature"] == true, "a branch nobody asked for opened itself")

  -- Nothing is read for a branch that is not open: a repository with a dozen
  -- of them would otherwise run a dozen logs to draw a panel showing one.
  wait_for(function()
    local list = panel.commit_lists[trunk]
    return list ~= nil and list.commits ~= nil
  end, "the checked-out branch's history never arrived")
  assert(panel.commit_lists.feature == nil, "a collapsed branch was read anyway")

  -- ── what the rows say ─────────────────────────────────────────────────
  local trunk_line = assert(line_matching(panel, "● " .. trunk), "the checked-out branch has no row")
  assert(select(2, line_matching(panel, "● " .. trunk)):find("↑1", 1, true), "the row does not say it is ahead")
  local feature_line = assert(line_matching(panel, "feature"), "the other branch has no row")
  assert(lines(panel)[feature_line]:find("▸", 1, true), "the collapsed branch is not drawn as collapsed")
  assert(line_matching(panel, "second on the trunk"), "the open branch's commits are not on screen")
  assert(not line_matching(panel, "only on feature"), "a collapsed branch put its commits on screen")
  assert(trunk_line < feature_line, "the checked-out branch is not first")

  -- A branch is one level in from the heading that lists it, and its commits
  -- one level in from the branch: the panel has four levels here and only the
  -- indent says which is which.
  local heading = assert(line_matching(panel, "BRANCHES"), "the panel has no BRANCHES heading")
  local rendered = lines(panel)
  local function indent(text)
    return #(text:match("^ *") or "")
  end
  assert(
    indent(rendered[trunk_line]) == indent(rendered[heading]) + 2,
    "a branch is not indented under the heading that lists it"
  )
  local commit_line = assert(line_matching(panel, "second on the trunk"), "the open branch has no commit rows")
  assert(
    indent(rendered[commit_line]) == indent(rendered[trunk_line]) + 2,
    "a commit is not indented under its branch"
  )

  -- ── opening one reads it, and only then ───────────────────────────────
  local row = assert(branch_row(panel, "feature"), "the feature branch has no entry")
  vim.api.nvim_set_current_win(panel.win)
  vim.api.nvim_win_set_cursor(panel.win, { row, 0 })
  vim.fn.maparg("<CR>", "n", false, true).callback()
  wait_for(function()
    local list = panel.commit_lists.feature
    return list ~= nil and list.commits ~= nil
  end, "opening a branch did not read its history")
  assert(line_matching(panel, "only on feature"), "the opened branch's own commit is not on screen")
  assert(panel.collapsed["branch:feature"] == false, "the branch did not stay open")

  -- Its history is its own, and it is remembered per branch.
  local depths = GitPanel._commit_depths[panel.root] or {}
  assert(depths[trunk] and depths.feature, "history depth is not remembered per branch")

  -- Closing it again leaves the commits behind but takes the rows away.
  vim.fn.maparg("<CR>", "n", false, true).callback()
  wait_for(function()
    return not line_matching(panel, "only on feature")
  end, "closing a branch left its commits on screen")

  -- ── a branch that goes away takes its section with it ─────────────────
  git({ "branch", "-D", "feature" })
  GitPanel.refresh(panel.buf)
  wait_for(function()
    return panel.branches ~= nil and #panel.branches == 1
  end, "the deleted branch kept its section")
  assert(panel.commit_lists.feature == nil, "the deleted branch kept its history")
  assert(panel.collapsed["branch:feature"] == nil, "the deleted branch kept its fold")
  assert(not line_matching(panel, "feature"), "the deleted branch is still drawn")
end)

pcall(ActivityBar.close)
pcall(GitPanel.close)
vim.o.columns = original_columns
vim.o.mousemoveevent = original_mousemove
vim.cmd.cd(vim.fn.fnameescape(original_cwd))
vim.fn.delete(root, "rf")
vim.fn.delete(remote, "rf")
assert(ok, test_error)

print("git-panel-branches-ok")
