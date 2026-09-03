local ActivityBar = require("config.activity_bar")
local GitPanel = require("config.git_panel")

local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")

local function git(args)
  local command = { "git", "-C", root }
  vim.list_extend(command, args)
  local result = vim.system(command, { text = true }):wait()
  assert(result.code == 0, table.concat(args, " ") .. ": " .. (result.stderr or ""))
end

local original_cwd = vim.fn.getcwd(0)
local original_columns = vim.o.columns

local function wait_for(condition, message)
  assert(vim.wait(5000, condition, 50), message)
end

local function listed(buf)
  return vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buflisted
end

local ok, test_error = pcall(function()
  vim.fn.writefile({ "int a = 1;", "int b = 2;" }, root .. "/tracked.c")
  vim.fn.writefile({ "int second = 2;" }, root .. "/second.c")
  vim.fn.writefile({ "int elsewhere = 3;" }, root .. "/other.c")
  git({ "init", "-q" })
  git({ "config", "user.name", "Preview Teardown Test" })
  git({ "config", "user.email", "preview-teardown@example.invalid" })
  git({ "add", "." })
  git({ "commit", "-qm", "the first commit" })
  vim.fn.writefile({ "int a = 1;", "int b = 22;" }, root .. "/tracked.c")
  vim.fn.writefile({ "int second = 22;" }, root .. "/second.c")

  vim.cmd.cd(vim.fn.fnameescape(root))
  vim.o.columns = 160
  ActivityBar.setup()

  local view = ActivityBar.open("git", { focus = false })
  wait_for(function()
    return view.content and view.content.kind == "git" and view.content.git_state
  end, "the Git panel did not open")
  local panel = view.content.git_state
  GitPanel.refresh(panel.buf, { status_only = true })

  local function open_diff(path)
    local row
    wait_for(function()
      for line, entry in pairs(panel.entries or {}) do
        if entry.kind == "worktree_file" and entry.path == path then
          row = line
          return true
        end
      end
    end, path .. " never appeared in the panel")
    vim.api.nvim_set_current_win(panel.win)
    vim.api.nvim_win_set_cursor(panel.win, { row, 0 })
    vim.fn.maparg("<CR>", "n", false, true).callback()
    wait_for(function()
      return panel.preview ~= nil and panel.preview_layout ~= nil
    end, "the diff never opened")
    return panel.preview
  end

  -- ── the file you are looking at survives the panel it came from ───────
  -- The working-tree side of a diff is the file itself, so opening the file
  -- under review -- from the explorer, say -- puts the diff's own buffer in
  -- the editor window, and nothing tears the layout down. Switching panels
  -- then destroys the Git panel, and what it takes down with it must not
  -- include the file the reader is reading.
  local preview = open_diff("tracked.c")
  assert(preview.after_is_file, "the working-tree side of this diff is not the file")
  local file_buf = preview.bufs[2]

  local editor = assert(ActivityBar.editor_window(), "there is no editor window")
  vim.api.nvim_set_current_win(editor)
  vim.cmd.edit(vim.fn.fnameescape(root .. "/tracked.c"))
  wait_for(function()
    return vim.api.nvim_win_get_buf(editor) == file_buf
  end, "opening the file under review did not put it in the editor window")

  ActivityBar.open("explorer", { focus = false })
  wait_for(function()
    local current = ActivityBar.current()
    return current.content and current.content.kind == "explorer"
  end, "the Explorer did not replace the Git panel")

  assert(vim.api.nvim_buf_is_valid(file_buf), "switching panels deleted the file being read")
  assert(listed(file_buf), "switching panels unlisted the file being read")
  local still = ActivityBar.editor_window()
  assert(
    still and vim.api.nvim_win_get_buf(still) == file_buf,
    "switching panels took the file off the screen"
  )

  -- ── and a diff nobody is reading is still cleaned up ──────────────────
  -- The panel opens a buffer to show the working-tree side; one left behind
  -- with nobody looking at it is the panel's to close, or every file glanced
  -- at in a diff would pile up in the tab bar.
  ActivityBar.open("git", { focus = false })
  wait_for(function()
    local current = ActivityBar.current()
    return current.content and current.content.kind == "git" and current.content.git_state
  end, "the Git panel did not come back")
  panel = ActivityBar.current().content.git_state
  GitPanel.refresh(panel.buf, { status_only = true })
  local reopened = open_diff("second.c")
  local diff_buf = reopened.bufs[2]
  assert(reopened.after_buf_ours, "the test did not manage to have the panel open the file itself")

  editor = assert(ActivityBar.editor_window(), "there is no editor window")
  vim.api.nvim_set_current_win(editor)
  vim.cmd.edit(vim.fn.fnameescape(root .. "/other.c"))
  wait_for(function()
    return panel.preview_layout == nil
  end, "opening another file did not put the diff away")

  ActivityBar.open("explorer", { focus = false })
  wait_for(function()
    return not vim.api.nvim_buf_is_valid(diff_buf) or not listed(diff_buf)
  end, "a diff nobody was reading was left behind in the tab bar")
end)

pcall(ActivityBar.close)
pcall(GitPanel.close)
vim.o.columns = original_columns
vim.cmd.cd(vim.fn.fnameescape(original_cwd))
vim.fn.delete(root, "rf")
assert(ok, test_error)

print("git-panel-preview-teardown-ok")
