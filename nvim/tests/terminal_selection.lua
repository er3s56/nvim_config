local ActivityBar = require("config.activity_bar")
local TerminalTabs = require("config.terminal_tabs")

local root = TerminalTabs._normalize_root(vim.fn.tempname())
vim.fn.mkdir(root, "p")

local original_cwd = vim.fn.getcwd(0)
local original_columns = vim.o.columns
local original_registers = { vim.fn.getreg('"'), vim.fn.getreg("+") }

local function wait_for(condition, message)
  assert(vim.wait(8000, condition, 50), message)
end

local function terminal()
  local group = TerminalTabs._groups[root]
  local item = group and group.active
  return item and item.terminal or nil
end

local function buffer_text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

-- A selection made the way a mouse drag makes one: Terminal-Normal first,
-- then Visual. `normal!` would finish the visual command and leave normal
-- mode behind, which is precisely the state under test.
local function select_line(win, buf, needle)
  vim.api.nvim_set_current_win(win)
  pcall(vim.cmd.stopinsert)
  local line
  for index, text in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if text:find(needle, 1, true) then
      line = index
    end
  end
  assert(line, ("the terminal never printed `%s`"):format(needle))
  vim.api.nvim_win_set_cursor(win, { line, 0 })
  -- `v` toggles, so a selection left standing by an earlier copy has to be
  -- dismissed first. A real drag does this for free: the press ends the
  -- selection and re-anchors in one gesture.
  vim.api.nvim_feedkeys(vim.keycode("<Esc>v$"), "nx", false)
end

local ok, test_error = pcall(function()
  vim.cmd.cd(vim.fn.fnameescape(root))
  vim.o.columns = 160
  ActivityBar.setup()
  ActivityBar.open("explorer", { focus = false })
  TerminalTabs.open(root, true)
  wait_for(function()
    local item = terminal()
    return item ~= nil and item:win_valid()
  end, "the project terminal never opened")

  local term = terminal()
  local win, buf = term.win, term.buf
  local job = vim.b[buf].terminal_job_id
  assert(job, "the terminal has no job to talk to")
  vim.fn.chansend(job, "echo hello-copy-me\n")
  wait_for(function()
    return buffer_text(buf):find("hello%-copy%-me\n") ~= nil
  end, "the terminal never echoed anything to select")

  -- ── the module itself ─────────────────────────────────────────────────
  assert(TerminalTabs.owns_window(win), "the project terminal's window is not recognised as one")
  assert(not TerminalTabs.pending_selection(), "a terminal with no selection reported one")

  select_line(win, buf, "hello-copy-me")
  assert(TerminalTabs.pending_selection(), "a selection in the terminal was not seen")
  assert(TerminalTabs.copy_selection(), "the selection was not copied")
  assert(vim.fn.getreg('"'):find("hello-copy-me", 1, true), "the copied text is not what was selected")
  -- And it is still standing: taking a copy must not make the selection
  -- disappear, or there is no way to see what was taken.
  assert(vim.api.nvim_get_mode().mode:find("v"), "the copy took the selection away with it")

  -- ── and the release that ends a drag is what runs it ──────────────────
  -- The gesture cannot be synthesised without a UI, but the mapping that
  -- receives it can be asked directly: with a selection standing in the
  -- terminal it has to swallow the release and copy, not pass it through.
  vim.fn.setreg('"', "")
  select_line(win, buf, "hello-copy-me")
  local release
  for _, map in ipairs(vim.api.nvim_get_keymap("x")) do
    if map.lhs == "<LeftRelease>" and map.callback then
      release = map.callback
    end
  end
  assert(release, "no global <LeftRelease> mapping to end a drag with")
  assert(release() == "", "the release that ends a terminal selection was passed through")
  wait_for(function()
    return vim.fn.getreg('"'):find("hello-copy-me", 1, true) ~= nil
  end, "the release did not copy the selection")
  assert(vim.api.nvim_get_mode().mode:find("v"), "the release took the selection away")

  -- A press that follows clears it: in Visual mode the press is delivered as
  -- it is, Neovim ends the selection, and the release then hands the terminal
  -- back to typing.
  assert(not TerminalTabs.press_needs_normal(win), "a press during a selection was asked to leave Terminal-Insert")
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  assert(not TerminalTabs.pending_selection(), "the selection survived being dismissed")

  -- Nothing else is touched: with no selection the release passes through.
  pcall(vim.cmd.stopinsert)
  assert(not TerminalTabs.pending_selection(), "Terminal-Normal alone counted as a selection")

  -- ── the press that starts a selection ─────────────────────────────────
  -- A press only anchors where it was aimed if it leaves Terminal-Insert
  -- first, and only the terminal's own windows get that treatment.
  vim.api.nvim_set_current_win(win)
  assert(not TerminalTabs.press_needs_normal(win), "Terminal-Normal was asked to leave itself")
  local editor = ActivityBar.editor_window()
  if editor then
    assert(not TerminalTabs.press_needs_normal(editor), "a press in the editor was treated as one in a terminal")
  end

  -- With no selection standing, the release is what hands typing back.
  assert(TerminalTabs.resume_typing(win), "the release did not hand the terminal back to typing")

  -- ── a right click in the terminal is swallowed at both ends ───────────
  -- Left to Neovim, the release drops the terminal out of Terminal-Insert:
  -- a right click that opens no menu would still change the mode.
  local real_getmousepos = vim.fn.getmousepos
  local function delivered(key, over)
    local mapping = vim.fn.maparg(key, "n", false, true)
    assert(type(mapping.callback) == "function", key .. " has no handler")
    vim.fn.getmousepos = function()
      return { winid = over, line = 1, column = 1, screenrow = 1, screencol = 1, winrow = 1, wincol = 1 }
    end
    local ok, produced = pcall(mapping.callback)
    vim.fn.getmousepos = real_getmousepos
    assert(ok, key .. " errored: " .. tostring(produced))
    return produced
  end

  assert(delivered("<RightMouse>", win) == "", "a right click in the terminal was passed to Neovim")
  assert(delivered("<RightRelease>", win) == "", "the release of a right click in the terminal was passed on")
  local editor_win = ActivityBar.editor_window()
  if editor_win then
    assert(delivered("<RightRelease>", editor_win) ~= "", "an ordinary window lost its own right click")
  end
end)

pcall(vim.cmd.stopinsert)
pcall(TerminalTabs.close_all, root)
pcall(ActivityBar.close)
vim.fn.setreg('"', original_registers[1])
pcall(vim.fn.setreg, "+", original_registers[2])
vim.o.columns = original_columns
vim.cmd.cd(vim.fn.fnameescape(original_cwd))
TerminalTabs._groups[root] = nil
vim.fn.delete(root, "rf")
assert(ok, test_error)

print("terminal-selection-ok")
