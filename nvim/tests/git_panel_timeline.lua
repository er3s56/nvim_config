local ActivityBar = require("config.activity_bar")
local GitPanel = require("config.git_panel")

local root = vim.fn.tempname()
local original_name = "old/name.txt"
local renamed = "src/renamed.txt"
local other = "src/other.txt"

local function absolute(path)
  return vim.fs.joinpath(root, path)
end

local function write(path, lines)
  local full = absolute(path)
  vim.fn.mkdir(vim.fs.dirname(full), "p")
  assert(vim.fn.writefile(lines, full) == 0)
end

local function git(args)
  local command = { "git", "-C", root }
  vim.list_extend(command, args)
  local result = vim.system(command, { text = true }):wait()
  assert(result.code == 0, table.concat(args, " ") .. ": " .. (result.stderr or ""))
  return result.stdout or ""
end

vim.fn.mkdir(root, "p")
git({ "init", "-q" })
git({ "config", "user.name", "Git Panel Test" })
git({ "config", "user.email", "git-panel@example.invalid" })

-- A history with a rename in it, so `--follow` has something to prove.
write(original_name, { "one" })
git({ "add", original_name })
git({ "commit", "-qm", "add the file" })
write(original_name, { "one", "two" })
git({ "commit", "-qam", "extend the file" })
vim.fn.mkdir(absolute("src"), "p")
git({ "mv", original_name, renamed })
git({ "commit", "-qm", "rename the file" })
write(renamed, { "one", "two", "three" })
git({ "commit", "-qam", "extend it again" })
write(other, { "unrelated" })
git({ "add", other })
git({ "commit", "-qm", "another file" })

local original_cwd = vim.fn.getcwd(0)
local original_columns = vim.o.columns
local original_mousemove = vim.o.mousemoveevent

local function wait_for(condition, message)
  assert(vim.wait(5000, condition, 50), message)
end

local function panel_line(panel, pattern)
  for index, text in ipairs(vim.api.nvim_buf_get_lines(panel.buf, 0, -1, false)) do
    if text:find(pattern, 1, true) then
      return index, text
    end
  end
end

local function entry_line(panel, predicate)
  for line, entry in pairs(panel.entries or {}) do
    if predicate(entry) then
      return line, entry
    end
  end
end

local ok, test_error = pcall(function()
  -- ── parsing, before any UI is involved ────────────────────────────────
  local parsed = GitPanel._parse_timeline(
    table.concat({
      ("a"):rep(40) .. "\taaaaaaa\tsubject one",
      "M\tsrc/renamed.txt",
      ("b"):rep(40) .. "\tbbbbbbb\tsubject two",
      "R100\told/name.txt\tsrc/renamed.txt",
    }, "\n"),
    renamed
  )
  assert(#parsed == 2, ("expected two commits, got %d"):format(#parsed))
  assert(parsed[1].kind == "commit_file", "a timeline row is not a commit's view of a file")
  assert(parsed[2].status == "R", "a rename was not recognised")
  assert(parsed[2].old_path == "old/name.txt", "a rename lost the name the file had then")
  assert(parsed[2].path == renamed, "a rename lost the name the file took")

  vim.cmd.cd(vim.fn.fnameescape(root))
  vim.cmd.edit(vim.fn.fnameescape(absolute(renamed)))
  vim.o.columns = 200
  ActivityBar.setup()

  local view = ActivityBar.open("git", { focus = false })
  wait_for(function()
    return view.content and view.content.kind == "git" and view.content.git_state
  end, "the Git panel did not open")
  local panel = view.content.git_state

  -- ── the history of the file in the editor ─────────────────────────────
  wait_for(function()
    return panel.timeline.path == renamed and panel.timeline.commits ~= nil
  end, "the timeline never followed the file in the editor")
  local commits = panel.timeline.commits
  assert(#commits == 4, ("--follow should reach past the rename, got %d commits"):format(#commits))
  assert(commits[1].subject == "extend it again", "the timeline is not newest first")
  assert(commits[2].status == "R" and commits[2].old_path == original_name, "the rename lost its old path")
  assert(commits[4].status == "A" and commits[4].path == original_name, "the first commit lost the original name")
  assert(panel.timeline.exhausted, "a four-commit history was not reported as complete")

  local header = select(2, panel_line(panel, "TIMELINE"))
  assert(header, "the panel has no TIMELINE section")
  assert(header:find("renamed.txt", 1, true), "the TIMELINE header does not name the file")
  assert(panel_line(panel, "extend it again"), "the timeline was not rendered")

  -- ── clicking a row opens that commit's diff of that file ──────────────
  local line = assert(entry_line(panel, function(entry)
    return entry.kind == "commit_file" and entry.subject == "rename the file"
  end), "the rename commit has no row")
  vim.api.nvim_set_current_win(panel.win)
  vim.api.nvim_win_set_cursor(panel.win, { line, 0 })
  vim.fn.maparg("<CR>", "n", false, true).callback()
  wait_for(function()
    return panel.preview ~= nil and panel.preview.entry.subject == "rename the file"
  end, "a timeline row did not open its diff")
  assert(panel.preview.mode == "commit", "history opened as something other than a commit diff")
  assert(panel.preview.after_label:find(commits[2].short_hash, 1, true), "the diff is labelled with the wrong commit")
  assert(#(panel.preview.hunk_marks or {}) == 0, "a commit's diff offered to change it")

  -- ── paging ────────────────────────────────────────────────────────────
  GitPanel._load_timeline(panel, { force = true, count = 2 })
  wait_for(function()
    return #(panel.timeline.commits or {}) == 2 and not panel.timeline.loading
  end, "the timeline did not reload as a single page")
  assert(not panel.timeline.exhausted, "a partial page was reported as the whole history")
  local more = assert(entry_line(panel, function(entry)
    return entry.kind == "timeline_load_more"
  end), "a partial history offered no way to load more")
  vim.api.nvim_set_current_win(panel.win)
  vim.api.nvim_win_set_cursor(panel.win, { more, 0 })
  vim.fn.maparg("<CR>", "n", false, true).callback()
  wait_for(function()
    return #(panel.timeline.commits or {}) == 4 and panel.timeline.exhausted
  end, "loading more history did not reach the end")

  -- ── it follows the editor ─────────────────────────────────────────────
  local editor = assert(ActivityBar.editor_window(), "the tab has no editor window to open a file in")
  vim.api.nvim_set_current_win(editor)
  vim.cmd.edit(vim.fn.fnameescape(absolute(other)))
  wait_for(function()
    return panel.timeline.path == other and panel.timeline.commits ~= nil
  end, "the timeline did not follow the editor to another file")
  assert(#panel.timeline.commits == 1, "the other file's history is not its own")
  assert(select(2, panel_line(panel, "TIMELINE")):find("other.txt", 1, true), "the header did not follow the file")

  -- Moving into the panel itself is not "no file open".
  vim.api.nvim_set_current_win(panel.win)
  GitPanel._sync_timeline(panel)
  assert(panel.timeline.path == other, "focusing the panel emptied the timeline")
end)

pcall(ActivityBar.close)
pcall(GitPanel.close)
vim.o.columns = original_columns
vim.o.mousemoveevent = original_mousemove
vim.cmd.cd(vim.fn.fnameescape(original_cwd))
vim.fn.delete(root, "rf")
assert(ok, test_error)

print("git-panel-timeline-ok")
