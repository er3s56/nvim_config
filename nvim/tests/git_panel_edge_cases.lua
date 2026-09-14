local A = require("config.activity_bar")
local P = require("config.git_panel")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local function write(path, text)
  local file = assert(io.open(root .. "/" .. path, "wb"))
  assert(file:write(text))
  file:close()
end
local function git(...)
  local args = { "git", "-C", root }
  vim.list_extend(args, { ... })
  local r = vim.system(args, { text = false }):wait()
  assert(r.code == 0, r.stderr)
  return r.stdout or ""
end
local function wait(predicate, label)
  assert(vim.wait(5000, predicate, 20), label)
end
local original_cwd, original_columns = vim.fn.getcwd(), vim.o.columns
local ok, err = xpcall(function()
  git("init", "-q")
  git("config", "user.name", "Panel Regression")
  git("config", "user.email", "panel@example.invalid")
  git("config", "core.autocrlf", "false")
  write(".gitattributes", "crlf.txt text eol=crlf\n")
  write("old.txt", "one\ntwo\nthree\nfour\nfive\n")
  write("target.txt", "valuable content\n")
  write("crlf.txt", "one\r\ntwo\r\nthree\r\nfour\r\nfive\r\n")
  assert(vim.uv.fs_symlink("old.txt", root .. "/link"))
  git("add", "--all")
  git("commit", "-qm", "fixture")
  assert(vim.uv.fs_unlink(root .. "/link"))
  assert(vim.uv.fs_symlink("target.txt", root .. "/link"))
  git("mv", "old.txt", "renamed.txt")
  write("renamed.txt", "one\nTWO\nthree\nfour\nfive\n")
  git("add", "renamed.txt")
  write("crlf.txt", "ONE\r\ntwo\r\nthree\r\nfour\r\nFIVE\r\n")
  vim.cmd.cd(root)
  vim.o.columns = 200
  local state = A.open("git", { focus = false })
  wait(function()
    return state.content and state.content.git_state and #(state.content.git_state.changes or {}) > 0
  end, "Git panel did not load")
  local panel = state.content.git_state
  local function preview(path, group)
    local row
    for line, entry in pairs(panel.entries) do
      if entry.kind == "worktree_file" and entry.path == path and entry.group == group then
        row = line
        break
      end
    end
    assert(row, "missing row " .. path .. " / " .. group)
    vim.api.nvim_set_current_win(panel.win)
    vim.api.nvim_win_set_cursor(panel.win, { row, 0 })
    vim.fn.maparg("<CR>", "n", false, true).callback()
    wait(function()
      return panel.preview and panel.preview.entry.path == path and panel.preview_layout
    end, "diff did not open")
    return panel.preview
  end
  local link = preview("link", "changes")
  assert(link.before == "old.txt" and link.after == "target.txt", "link diff showed target file contents")
  assert(not link.after_is_file, "link diff opened an editable target file")
  assert(#link.hunks == 0 and link.hunk_error, "link still has hunk buttons")
  for _, item in ipairs(P._preview_context_entries(panel, link, "after", { line = 1 })) do
    if item.label == "Stage Hunk" or item.label == "Discard Hunk" then
      assert(item.enabled == false, "link hunk menu remained enabled")
    end
  end
  assert(table.concat(vim.fn.readfile(root .. "/target.txt"), "\n") == "valuable content")

  local renamed = preview("renamed.txt", "staged")
  assert(#renamed.hunks == 1)
  local unstage
  for _, item in ipairs(P._preview_context_entries(panel, renamed, "after", { line = 2 })) do
    if item.label == "Unstage Hunk" then
      assert(item.enabled ~= false)
      unstage = item.action
    end
  end
  assert(unstage, "rename lacks an unstage action")()
  wait(function()
    return git("show", ":renamed.txt") == "one\ntwo\nthree\nfour\nfive\n"
  end, "rename unstage did not reach the old HEAD path")
  wait(function()
    return not panel.refreshing
  end, "panel refresh did not finish")
  local crlf = preview("crlf.txt", "changes")
  assert(#crlf.hunks == 2, "CRLF preview did not isolate the two changed lines")
  local stage
  for _, item in ipairs(P._preview_context_entries(panel, crlf, "after", { line = 1 })) do
    if item.label == "Stage Hunk" then
      assert(item.enabled ~= false)
      stage = item.action
    end
  end
  assert(stage)()
  wait(function()
    return git("show", ":crlf.txt") == "ONE\ntwo\nthree\nfour\nfive\n"
  end, "panel staging bypassed clean/eol rules")
end, debug.traceback)
A.close()
vim.cmd.cd(original_cwd)
vim.o.columns = original_columns
pcall(require("gitsigns").detach_all)
vim.wait(300)
vim.fn.delete(root, "rf")
assert(ok, err)
print("git-panel-edge-cases-ok")
