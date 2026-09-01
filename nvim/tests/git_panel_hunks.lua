local ActivityBar = require("config.activity_bar")
local GitPanel = require("config.git_panel")

local root = vim.fn.tempname()
local relative = "src/file.txt"
local file = vim.fs.joinpath(root, relative)
vim.fn.mkdir(vim.fs.dirname(file), "p")
local committed = { "one", "two", "three", "four", "five", "six", "seven", "eight" }
assert(vim.fn.writefile(committed, file) == 0)

local function git(args)
  local command = { "git", "-C", root }
  vim.list_extend(command, args)
  local result = vim.system(command, { text = true }):wait()
  assert(result.code == 0, table.concat(args, " ") .. ": " .. (result.stderr or ""))
  return result.stdout or ""
end

git({ "init", "-q" })
git({ "config", "user.name", "Git Panel Test" })
git({ "config", "user.email", "git-panel@example.invalid" })
git({ "add", relative })
git({ "commit", "-qm", "initial" })

local original_cwd = vim.fn.getcwd(0)
local original_columns = vim.o.columns
local original_mousemove = vim.o.mousemoveevent

local function row_of(panel, path)
  for line, entry in pairs(panel.entries or {}) do
    if entry.kind == "worktree_file" and entry.path == path then
      return line
    end
  end
end

-- Where a hunk's buttons are on screen. The strip is virtual text, so it
-- starts where the cursor would sit at the end of the line, and `offset` walks
-- across it a cell at a time.
local function hunk_mouse(panel, line, offset)
  local win = panel.preview_layout.after_win
  local text = vim.api.nvim_buf_get_lines(panel.preview.bufs[2], line - 1, line, false)[1] or ""
  local position = vim.fn.screenpos(win, line, #text + 1)
  return {
    winid = win,
    line = line,
    column = #text + 1,
    screenrow = position.row,
    screencol = position.col + offset - 1,
  }
end

local function button_named(panel, line, action)
  for _, range in ipairs((panel.preview.hunk_marks or {})[line] or {}) do
    if range.action == action then
      return range
    end
  end
end

local function marked_lines(panel)
  local lines = {}
  for line in pairs(panel.preview.hunk_marks or {}) do
    lines[#lines + 1] = line
  end
  table.sort(lines)
  return lines
end

local function wait_for(condition, message)
  assert(vim.wait(5000, condition, 50), message)
end

local ok, test_error = pcall(function()
  vim.cmd.cd(vim.fn.fnameescape(root))
  vim.cmd.edit(vim.fn.fnameescape(file))
  vim.o.columns = 200
  ActivityBar.setup()

  local view = ActivityBar.open("git", { focus = false })
  wait_for(function()
    return view.content and view.content.kind == "git" and view.content.git_state
  end, "the Git panel did not open")
  local panel = view.content.git_state

  -- Two edits far enough apart to stay two hunks.
  local edited = vim.deepcopy(committed)
  edited[2] = "TWO"
  edited[7] = "SEVEN"
  assert(vim.fn.writefile(edited, file) == 0)
  GitPanel.refresh(panel.buf, { status_only = true })
  wait_for(function()
    return row_of(panel, relative) ~= nil
  end, "the modified file never appeared in CHANGES")

  -- Open the diff the way <CR> does.
  local row = row_of(panel, relative)
  vim.api.nvim_set_current_win(panel.win)
  vim.api.nvim_win_set_cursor(panel.win, { row, 0 })
  vim.fn.maparg("<CR>", "n", false, true).callback()
  wait_for(function()
    return panel.preview_layout ~= nil
      and panel.preview ~= nil
      and vim.api.nvim_win_is_valid(panel.preview_layout.after_win)
  end, "the diff never opened")

  local preview = panel.preview
  assert(preview.mode == "unstaged", "an unstaged change opened in mode " .. tostring(preview.mode))
  assert(#preview.hunks == 2, ("expected two hunks, got %d"):format(#preview.hunks))
  assert(#marked_lines(panel) == 2, "not every hunk carries buttons")
  assert(vim.deep_equal(marked_lines(panel), { 2, 7 }), "the buttons are not on the changed lines")

  -- Both actions an unstaged hunk allows, and nothing else.
  local stage = assert(button_named(panel, 2, "stage"), "a hunk offered no stage button")
  local discard = assert(button_named(panel, 2, "discard"), "a hunk offered no discard button")
  assert(not button_named(panel, 2, "unstage"), "an unstaged hunk offered to unstage")
  assert(discard.to < stage.from, "the destructive button is not the outermost one")
  -- A cell of slack between the two, so a click that lands a column off does
  -- nothing rather than the wrong thing.
  assert(stage.from - discard.to > 1, "the hunk buttons have no gap between them")
  assert(GitPanel._preview_button_hit(hunk_mouse(panel, 2, discard.to + 1)) == nil, "the gap is clickable")
  assert(GitPanel._preview_button_hit(hunk_mouse(panel, 2, stage.from)) ~= nil, "the stage button is not clickable")
  assert(GitPanel._preview_button_hit(hunk_mouse(panel, 4, 1)) == nil, "an unchanged line offered a hunk button")

  -- ── staging one hunk ──────────────────────────────────────────────────
  assert(GitPanel._handle_preview_click(hunk_mouse(panel, 2, stage.from)), "the stage click was not handled")
  wait_for(function()
    return git({ "show", ":" .. relative }) ~= table.concat(committed, "\n") .. "\n"
  end, "staging a hunk changed nothing in the index")
  local staged = git({ "show", ":" .. relative })
  assert(staged:find("TWO", 1, true), "the staged hunk did not reach the index")
  assert(not staged:find("SEVEN", 1, true), "staging one hunk took the other with it")
  assert(table.concat(vim.fn.readfile(file), "\n") == table.concat(edited, "\n"), "staging touched the working tree")

  -- The diff stays open across the action and re-reads itself: what is left is
  -- the one hunk that is still unstaged.
  wait_for(function()
    return #(panel.preview.hunks or {}) == 1
  end, "the diff did not follow the file into its new status")
  assert(panel.preview == preview, "the diff was replaced instead of reloaded")
  assert(vim.api.nvim_win_is_valid(panel.preview_layout.after_win), "the diff window closed")
  assert(panel.preview.mode == "unstaged", "the reloaded diff lost its mode")
  assert(vim.deep_equal(marked_lines(panel), { 7 }), "the buttons did not move with the remaining hunk")

  -- ── the diff's own menu ───────────────────────────────────────────────
  local menu = GitPanel._preview_context_entries(panel, panel.preview, "after", { line = 7 })
  local labels = {}
  for _, item in ipairs(menu) do
    if item.label then
      labels[item.label] = item.enabled ~= false
    end
  end
  assert(labels["Stage Hunk"], "the diff menu cannot stage the hunk under the pointer")
  assert(labels["Discard Hunk"], "the diff menu cannot discard the hunk under the pointer")
  -- The whole-file actions are the ones the row this diff came from has. That
  -- row is in CHANGES -- staging one hunk left the other one unstaged -- so
  -- unstaging belongs to the file's other row, in STAGED CHANGES, and is not
  -- on offer here however staged the rest of the file now is.
  assert(labels["Stage Changes"], "the diff menu lost the whole-file actions")
  assert(labels["Discard Changes"], "the diff of an unstaged change could not discard the file")
  assert(labels["Unstage Changes"] == false, "the diff of an unstaged change offered to unstage it")
  local away = GitPanel._preview_context_entries(panel, panel.preview, "after", { line = 4 })
  for _, item in ipairs(away) do
    if item.label == "Stage Hunk" then
      assert(item.enabled == false, "the diff menu staged a hunk from a line that has none")
    end
  end

  -- ── discarding a hunk asks first ──────────────────────────────────────
  local remaining = assert(button_named(panel, 7, "discard"), "the remaining hunk offered no discard button")
  assert(GitPanel._handle_preview_click(hunk_mouse(panel, 7, remaining.from)), "the discard click was not handled")
  local function confirm_window()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == "git_panel_confirm" then
        return win, buf
      end
    end
  end
  wait_for(confirm_window, "discarding a hunk did not ask for confirmation")
  assert(vim.fn.readfile(file)[7] == "SEVEN", "the hunk was discarded before the question")

  local confirm_win, confirm_buf = confirm_window()
  local choice
  for index, text in ipairs(vim.api.nvim_buf_get_lines(confirm_buf, 0, -1, false)) do
    if text:find("Discard Hunk", 1, true) then
      choice = index
    end
  end
  assert(choice, "the confirmation offered no way to go ahead")
  vim.api.nvim_set_current_win(confirm_win)
  vim.api.nvim_win_set_cursor(confirm_win, { choice, 0 })
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(confirm_buf, "n")) do
    if map.lhs == "<CR>" and map.callback then
      map.callback()
    end
  end
  wait_for(function()
    return vim.fn.readfile(file)[7] == "seven"
  end, "the hunk was never discarded")
  assert(vim.fn.readfile(file)[2] == "TWO", "discarding one hunk reverted the staged one as well")
end)

pcall(ActivityBar.close)
pcall(GitPanel.close)
vim.o.columns = original_columns
vim.o.mousemoveevent = original_mousemove
vim.cmd.cd(vim.fn.fnameescape(original_cwd))
vim.fn.delete(root, "rf")
assert(ok, test_error)

print("git-panel-hunks-ok")
