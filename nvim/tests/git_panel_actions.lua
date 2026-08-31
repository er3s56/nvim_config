local ActivityBar = require("config.activity_bar")
local GitPanel = require("config.git_panel")

local root = vim.fn.tempname()
local relative = "src/file.txt"
local file = vim.fs.joinpath(root, relative)
vim.fn.mkdir(vim.fs.dirname(file), "p")
local committed = { "one", "two", "three" }
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

local function status_of(path)
  for _, line in ipairs(vim.split(git({ "status", "--porcelain" }), "\n", { trimempty = true })) do
    if line:sub(4) == path then
      return line:sub(1, 2)
    end
  end
end

-- Wait for the panel's own view of a path, not just for git: an action is only
-- finished once the refresh it triggers has redrawn the rows the next click
-- will use.
local function wait_for_change(panel, path, wanted)
  local seen
  local reached = vim.wait(5000, function()
    seen = nil
    for _, change in ipairs(panel.changes or {}) do
      if change.path == path then
        seen = change.status
      end
    end
    return seen == wanted
  end, 50)
  assert(reached, ("the panel never showed `%s` as `%s` (it shows %s)"):format(path, tostring(wanted), tostring(seen)))
  assert(status_of(path) == wanted, ("git disagrees with the panel about `%s`"):format(path))
end

-- The panel row for a change, and where its buttons ended up on screen.
local function row_of(panel, path)
  for line, entry in pairs(panel.entries or {}) do
    if entry.kind == "worktree_file" and entry.path == path then
      return line
    end
  end
end

local function mouse_for(panel, line, column)
  local position = vim.fn.screenpos(panel.win, line, 1)
  return {
    winid = panel.win,
    line = line,
    column = column or 1,
    screenrow = position.row,
    screencol = position.col,
  }
end

local function button_named(panel, line, action)
  for _, range in ipairs((panel.buttons or {})[line] or {}) do
    if range.action == action then
      return range
    end
  end
end

local ok, test_error = pcall(function()
  vim.cmd.cd(vim.fn.fnameescape(root))
  vim.cmd.edit(vim.fn.fnameescape(file))
  vim.o.columns = 160
  ActivityBar.setup()

  local view = ActivityBar.open("git", { focus = false })
  assert(
    vim.wait(5000, function()
      return view.content and view.content.kind == "git" and view.content.git_state
    end),
    "the Git panel did not open"
  )
  local panel = view.content.git_state

  -- Pointer tracking is what makes the buttons appear under the pointer, and
  -- the terminal only reports it while this option is on.
  assert(vim.o.mousemoveevent, "the panel did not turn on pointer movement reporting")

  vim.fn.writefile({ "ONE", "two", "three" }, file)
  GitPanel.refresh(panel.buf, { status_only = true })
  assert(
    vim.wait(5000, function()
      return row_of(panel, relative) ~= nil
    end),
    "the modified file never appeared in CHANGES"
  )

  -- ── the row under the pointer carries the actions ──────────────────────
  local line = row_of(panel, relative)
  GitPanel._handle_mouse_move(mouse_for(panel, line, 1))
  assert(panel.hover_line == line, "the panel did not follow the pointer")
  local stage = button_named(panel, line, "stage")
  local discard = button_named(panel, line, "discard")
  assert(stage, "an unstaged change offered no stage button")
  assert(discard, "an unstaged change offered no discard button")
  assert(not button_named(panel, line, "unstage"), "an unstaged change offered to unstage")
  local rendered = vim.api.nvim_buf_get_lines(panel.buf, line - 1, line, false)[1]
  assert(rendered:sub(stage.from, stage.to):find("+", 1, true), "the stage button is not where the click test looks")
  assert(rendered:find(vim.fs.basename(relative), 1, true), "the buttons pushed the file name off the row")

  -- No other row may carry them at the same time.
  local section_line = line - 1
  assert((panel.buttons or {})[section_line] == nil, "two rows showed their actions at once")

  -- ── clicking a button acts, clicking the row does not ─────────────────
  GitPanel._activate_click(panel, mouse_for(panel, line, 3))
  vim.wait(300)
  assert(status_of(relative) == " M", "clicking the file name changed the repository")

  GitPanel._activate_click(panel, mouse_for(panel, line, stage.from))
  wait_for_change(panel, relative, "M ")

  -- A staged file offers the opposite action, in the same place.
  line = row_of(panel, relative)
  GitPanel._handle_mouse_move(mouse_for(panel, line, 1))
  local unstage = button_named(panel, line, "unstage")
  assert(unstage, "a staged change offered no unstage button")
  assert(not button_named(panel, line, "stage"), "a staged change still offered to stage")
  GitPanel._activate_click(panel, mouse_for(panel, line, unstage.from))
  wait_for_change(panel, relative, " M")

  -- ── discarding asks first ─────────────────────────────────────────────
  line = row_of(panel, relative)
  GitPanel._handle_mouse_move(mouse_for(panel, line, 1))
  discard = assert(button_named(panel, line, "discard"), "the discard button disappeared")
  GitPanel._activate_click(panel, mouse_for(panel, line, discard.from))

  local function confirm_window()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == "git_panel_confirm" then
        return win, buf
      end
    end
  end
  assert(
    vim.wait(5000, function()
      return confirm_window() ~= nil
    end),
    "discarding a file did not ask for confirmation"
  )
  assert(table.concat(vim.fn.readfile(file), "\n"):find("ONE"), "the file was discarded before the question")

  local confirm_win, confirm_buf = confirm_window()
  local lines = vim.api.nvim_buf_get_lines(confirm_buf, 0, -1, false)
  local choice
  for index, text in ipairs(lines) do
    if text:find("Discard Changes", 1, true) then
      choice = index
    end
  end
  assert(choice, "the confirmation offered no way to go ahead")
  assert(lines[1]:find(relative, 1, true), "the confirmation does not say what will be discarded")
  vim.api.nvim_set_current_win(confirm_win)
  vim.api.nvim_win_set_cursor(confirm_win, { choice, 0 })
  local activate
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(confirm_buf, "n")) do
    if map.lhs == "<CR>" and map.callback then
      activate = map.callback
    end
  end
  assert(activate, "the confirmation has no <CR> mapping")
  activate()
  wait_for_change(panel, relative, nil)
  assert(vim.fn.readfile(file)[1] == committed[1], "discarding did not restore the file")
end)

pcall(ActivityBar.close)
pcall(GitPanel.close)
vim.o.columns = original_columns
vim.o.mousemoveevent = original_mousemove
vim.cmd.cd(vim.fn.fnameescape(original_cwd))
vim.fn.delete(root, "rf")
assert(ok, test_error)

print("git-panel-actions-ok")
