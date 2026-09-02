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

  -- A worktree diff describes how a file currently differs from the index.
  -- When the file stops being a change, that difference is gone -- but the
  -- preview used to stay on screen, showing a diff of a file that no longer
  -- exists next to a CHANGES list reading "Working tree clean", with its
  -- buffer still listed in the tabline.
  do
    local untracked = vim.fs.joinpath(root, "vanishes.txt")
    assert(vim.fn.writefile({ "a", "b", "c" }, untracked) == 0)
    local panel = open_git()
    GitPanel.refresh(panel.buf, { full = true })
    assert(
      vim.wait(10000, function()
        for _, change in ipairs(panel.changes or {}) do
          if change.path:find("vanishes", 1, true) then
            return true
          end
        end
        return false
      end),
      "the new file never showed up in CHANGES"
    )

    local target
    for line, entry in pairs(panel.entries or {}) do
      if type(entry) == "table" and entry.kind == "worktree_file" and entry.path:find("vanishes", 1, true) then
        target = line
      end
    end
    assert(target, "the new file has no row to open")
    vim.api.nvim_set_current_win(panel.win)
    vim.api.nvim_win_set_cursor(panel.win, { target, 0 })
    vim.api.nvim_feedkeys(vim.keycode("<CR>"), "xt", false)
    assert(
      vim.wait(10000, function()
        return panel.preview ~= nil
      end),
      "the diff preview never opened"
    )
    local preview_bufs = vim.deepcopy(panel.preview.bufs)

    assert(vim.fn.delete(untracked) == 0, "the test could not remove the file")
    GitPanel.refresh(panel.buf, { full = true })
    assert(
      vim.wait(10000, function()
        return change_count(panel) == 0
      end),
      "CHANGES did not go back to clean"
    )
    vim.wait(500)
    assert(panel.preview == nil, "the diff preview outlived the change it was describing")
    for _, buf in ipairs(preview_bufs) do
      assert(not vim.api.nvim_buf_is_valid(buf), "a stale preview buffer was left in the tabline")
    end
    assert(vim.tbl_count(panel.previews or {}) == 0, "a stale preview stayed in the cache")
  end

  -- Previews are cached by entry, so the one that is merely cached goes stale
  -- as surely as the visible one -- and would be handed back, contents and
  -- all, the next time a file of that name and status appeared.
  do
    local gone = vim.fs.joinpath(root, "cached.txt")
    local stays = vim.fs.joinpath(root, "stays.txt")
    assert(vim.fn.writefile({ "one" }, gone) == 0)
    assert(vim.fn.writefile({ "two" }, stays) == 0)
    local panel = open_git()
    GitPanel.refresh(panel.buf, { full = true })
    assert(
      vim.wait(10000, function()
        return change_count(panel) >= 2
      end),
      "the two new files never showed up in CHANGES"
    )
    vim.api.nvim_set_current_win(panel.win)

    local function open_diff(needle)
      local row
      for line, entry in pairs(panel.entries or {}) do
        if type(entry) == "table" and entry.kind == "worktree_file" and entry.path:find(needle, 1, true) then
          row = line
        end
      end
      assert(row, ("no row for %s"):format(needle))
      -- Opening a diff moves the focus into it, so the panel has to be made
      -- current again before the next row can be activated.
      vim.api.nvim_set_current_win(panel.win)
      vim.api.nvim_win_set_cursor(panel.win, { row, 0 })
      vim.api.nvim_feedkeys(vim.keycode("<CR>"), "xt", false)
      assert(
        vim.wait(10000, function()
          return panel.preview ~= nil and panel.preview.entry.path:find(needle, 1, true) ~= nil
        end),
        ("the diff for %s never opened"):format(needle)
      )
      return panel.preview
    end

    local cached = open_diff("cached")
    local cached_bufs = vim.deepcopy(cached.bufs)
    local active = open_diff("stays")
    assert(panel.preview == active, "the second diff did not become the visible one")
    assert(panel.previews[cached.key] == cached, "the first diff was not kept in the cache")

    assert(vim.fn.delete(gone) == 0, "the test could not remove the file")
    GitPanel.refresh(panel.buf, { full = true })
    assert(
      vim.wait(10000, function()
        return change_count(panel) == 1
      end),
      "CHANGES did not drop the removed file"
    )
    vim.wait(500)
    assert(panel.previews[cached.key] == nil, "a cached diff of a vanished file was kept")
    for _, buf in ipairs(cached_bufs) do
      assert(not vim.api.nvim_buf_is_valid(buf), "a cached preview buffer was left in the tabline")
    end
    assert(panel.preview == active, "clearing the cache took the visible diff with it")
    assert(vim.fn.delete(stays) == 0, "the test could not clean up")
    GitPanel.refresh(panel.buf, { full = true })
    assert(
      vim.wait(10000, function()
        return change_count(panel) == 0
      end),
      "CHANGES did not go back to clean"
    )
  end

  -- ...and only worktree diffs. A commit's contents do not change, so a
  -- commit diff stays valid however the working tree moves, and dropping it
  -- along with the stale ones is the easy way to overshoot this fix.
  do
    local panel = open_git()
    -- Commits load asynchronously and a full refresh restarts that, so wait
    -- for a row rather than reading whatever happens to be rendered.
    local commit_row
    assert(
      vim.wait(10000, function()
        commit_row = nil
        for line, entry in pairs(panel.entries or {}) do
          if type(entry) == "table" and entry.kind == "commit" then
            commit_row = commit_row or line
          end
        end
        return commit_row ~= nil
      end),
      "no commit to expand"
    )
    vim.api.nvim_set_current_win(panel.win)
    vim.api.nvim_win_set_cursor(panel.win, { commit_row, 0 })
    vim.api.nvim_feedkeys(vim.keycode("<CR>"), "xt", false)
    local file_row
    assert(
      vim.wait(10000, function()
        for line, entry in pairs(panel.entries or {}) do
          if type(entry) == "table" and entry.kind == "commit_file" then
            file_row = line
            return true
          end
        end
        return false
      end),
      "expanding the commit listed no files"
    )
    vim.api.nvim_win_set_cursor(panel.win, { file_row, 0 })
    vim.api.nvim_feedkeys(vim.keycode("<CR>"), "xt", false)
    assert(
      vim.wait(10000, function()
        return panel.preview ~= nil and panel.preview.entry.kind == "commit_file"
      end),
      "the commit diff never opened"
    )
    local commit_preview = panel.preview

    -- Move the working tree underneath it.
    assert(vim.fn.writefile({ "touched while a commit diff was open" }, file) == 0)
    GitPanel.refresh(panel.buf, { full = true })
    assert(
      vim.wait(10000, function()
        return change_count(panel) > 0
      end),
      "the working-tree change never registered"
    )
    vim.wait(500)
    assert(panel.preview == commit_preview, "a refresh threw away the commit diff being read")
    for _, buf in ipairs(commit_preview.bufs) do
      assert(vim.api.nvim_buf_is_valid(buf), "a commit diff buffer was wiped by a worktree refresh")
    end
    git({ "checkout", "--", relative })
  end

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
  local list = assert(panel.commit_lists[panel.branch], "the checked-out branch has no history")
  local before = #(list.commits or {})
  git({ "add", "-A" })
  git({ "commit", "-qm", "second" })
  assert(
    vim.wait(10000, function()
      local current = panel.commit_lists[panel.branch]
      return current ~= nil and #(current.commits or {}) == before + 1 and change_count(panel) == 0
    end),
    ("the Git directory watcher did not reload after a commit (commits=%d changes=%d)"):format(
      #((panel.commit_lists[panel.branch] or {}).commits or {}),
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
