local ActivityBar = require("config.activity_bar")
local FindInFile = require("config.find_in_file")
local TerminalTabs = require("config.terminal_tabs")

local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local a = vim.fs.joinpath(root, "a.txt")
local b = vim.fs.joinpath(root, "b.txt")
assert(vim.fn.writefile({ "first needle", "plain line", "second needle", "third needle" }, a) == 0)
assert(vim.fn.writefile({ "other one", "other two" }, b) == 0)

local function wait(ms, condition, message)
  assert(vim.wait(ms, condition), message)
end

local function strip()
  return FindInFile._strips[vim.api.nvim_get_current_tabpage()]
end

local function picker()
  local current = strip()
  local candidate = current and current.picker
  return candidate and not candidate.closed and candidate or nil
end

-- The strip is on screen, its matcher has finished, and it lists `count` rows.
-- Snacks shows (and focuses) a picker on the updater tick after its results
-- arrive, so finished results alone do not mean the windows are up yet.
local function settled(count)
  return function()
    local current = picker()
    return current ~= nil and current.shown == true and not current:is_active() and current.list:count() == count
  end
end

local function width(win)
  return vim.api.nvim_win_get_width(win)
end

local original_cwd = vim.fn.getcwd(0)
local ok, test_error = pcall(function()
  vim.cmd.cd(vim.fn.fnameescape(root))
  ActivityBar.setup()
  FindInFile.setup()
  local state = ActivityBar.open("explorer", { focus = false })
  wait(3000, function()
    return state.content and state.content.kind == "explorer" and ActivityBar._content_root(state.content)
  end, "Explorer did not become ready")
  local editor = assert(ActivityBar.editor_window())
  vim.api.nvim_set_current_win(editor)
  vim.cmd.edit(vim.fn.fnameescape(a))
  local buf_a = vim.api.nvim_get_current_buf()

  -- Not everything is a place to search.
  assert(not FindInFile._searchable(ActivityBar._content_root(state.content)), "the sidebar counted as searchable")
  TerminalTabs.open(root, false)
  wait(5000, function()
    local group = TerminalTabs._groups[TerminalTabs._normalize_root(root)]
    return group and group.active and group.active.terminal:win_valid()
  end, "the project terminal did not become ready")
  local terminal_win = TerminalTabs._groups[TerminalTabs._normalize_root(root)].active.terminal.win
  assert(not FindInFile._searchable(terminal_win), "the terminal counted as searchable")
  assert(FindInFile._searchable(editor), "the editor did not count as searchable")

  -- Open on a.txt with a query.
  vim.api.nvim_set_current_win(editor)
  FindInFile.open("needle")
  wait(3000, settled(3), "the strip did not list the three matching lines")
  local first = assert(picker())
  assert(first.main == editor, "the strip does not preview into the editor window")
  assert(vim.api.nvim_get_current_win() == first.input.win.win, "opening did not focus the input")
  assert(vim.b[buf_a].find_in_file.open == true, "a.txt does not remember an open strip")

  -- Docked to the editor: same left edge, same width, directly beneath it, and
  -- above the terminal rather than below it.
  local dock = assert(strip().dock, "the strip has no split of its own")
  assert(vim.api.nvim_win_get_config(dock).relative == "", "the dock is a float, not a split")
  assert(not FindInFile._searchable(dock), "the dock counted as searchable")
  local editor_pos, dock_pos = vim.api.nvim_win_get_position(editor), vim.api.nvim_win_get_position(dock)
  assert(dock_pos[2] == editor_pos[2], "the strip does not start at the editor's left edge")
  local dock_width = width(dock)
  assert(dock_width == width(editor), ("the dock is %d wide, the editor %d"):format(dock_width, width(editor)))
  local editor_bottom = editor_pos[1] + vim.api.nvim_win_get_height(editor)
  assert(
    dock_pos[1] >= editor_bottom and dock_pos[1] <= editor_bottom + 1,
    ("the strip starts at row %d, the editor ends at %d"):format(dock_pos[1], editor_bottom)
  )
  assert(
    dock_pos[1] < vim.api.nvim_win_get_position(terminal_win)[1],
    "the strip went under the terminal instead of under the editor"
  )
  assert(vim.wo[dock].winfixheight, "the strip's height is not fixed")

  -- The picker floats over the dock edge to edge.
  local float = first.layout.root.win
  local float_config = vim.api.nvim_win_get_config(float)
  assert(float_config.relative == "win" and float_config.win == dock, "the picker does not float over the dock")
  assert(width(float) == dock_width, ("the picker is %d wide over a dock %d wide"):format(width(float), dock_width))

  -- A window opening to the right of the editor column narrows the dock
  -- without moving it. The strip has to follow, both ways. WinResized is
  -- checked for in the main loop, which a `-l` script never runs, so the
  -- handler is driven by hand here with the windows the event would carry.
  vim.api.nvim_set_current_win(editor)
  vim.cmd("botright vsplit")
  local aside = vim.api.nvim_get_current_win()
  local narrowed = width(dock)
  assert(narrowed < dock_width, "a window on the right did not narrow the dock")
  FindInFile._resized({ editor, dock })
  assert(width(float) == narrowed, ("the strip is %d wide over a dock %d wide"):format(width(float), narrowed))
  -- The freed columns are shared out again, not necessarily as they were.
  vim.api.nvim_win_close(aside, true)
  assert(width(dock) > narrowed, "closing the window on the right did not widen the dock back")
  FindInFile._resized({ editor, dock })
  assert(width(float) == width(dock), ("the strip is %d wide over a dock %d wide"):format(width(float), width(dock)))

  -- Esc closes from Insert mode in the input.
  local esc = vim.api.nvim_buf_call(first.input.win.buf, function()
    return vim.fn.maparg("<Esc>", "i", false, true)
  end)
  assert(esc.buffer == 1, "Esc in Insert mode is not bound in the strip's input")

  -- Ctrl+F while the strip is up focuses it rather than opening another.
  vim.api.nvim_set_current_win(editor)
  FindInFile.open()
  assert(picker() == first, "a second Ctrl+F replaced the strip")
  assert(vim.api.nvim_get_current_win() == first.input.win.win, "a second Ctrl+F did not focus the input")

  -- Choose the second match, then switch the editor to b.txt: the strip folds
  -- and a.txt keeps the query and the row.
  first.list:move(2, true, true)
  vim.api.nvim_set_current_win(editor)
  vim.cmd.edit(vim.fn.fnameescape(b))
  local buf_b = vim.api.nvim_get_current_buf()
  wait(3000, function()
    return picker() == nil
  end, "switching buffers did not fold the strip")
  local kept = vim.b[buf_a].find_in_file
  assert(
    kept.open == true and kept.pattern == "needle" and kept.cursor == 2,
    "folding lost the query or the row: " .. vim.inspect(kept)
  )
  vim.wait(300)
  assert(picker() == nil, "a buffer that never had a strip got one")

  -- b.txt: open, then close by hand. It remembers the query but not the strip.
  vim.api.nvim_set_current_win(editor)
  FindInFile.open("other")
  wait(3000, settled(2), "the strip did not list b.txt's two matches")
  assert(strip().buf == buf_b, "the strip is not bound to b.txt")
  FindInFile.close()
  wait(3000, function()
    return picker() == nil
  end, "closing by hand did not close")
  local closed = vim.b[buf_b].find_in_file
  assert(
    closed.open == false and closed.pattern == "other",
    "closing by hand was not remembered: " .. vim.inspect(closed)
  )

  -- Back to a.txt: the strip unfolds on its own, query and row intact, and
  -- without taking the focus.
  vim.api.nvim_set_current_win(editor)
  vim.cmd.edit(vim.fn.fnameescape(a))
  wait(3000, settled(3), "returning to a.txt did not unfold its strip")
  local second = assert(picker())
  assert(second ~= first, "the folded strip was reused rather than rebuilt")
  assert(second.input.filter.pattern == "needle", "unfolding lost the query")
  wait(3000, function()
    return second.list.cursor == 2
  end, "unfolding lost the selected row")
  assert(vim.api.nvim_get_current_win() == editor, "unfolding stole the focus")

  -- Back to b.txt: closed by hand, so it stays closed.
  vim.cmd.edit(vim.fn.fnameescape(b))
  wait(3000, function()
    return picker() == nil
  end, "leaving a.txt did not fold its strip")
  vim.wait(300)
  assert(picker() == nil, "a strip closed by hand came back")

  -- Back to a.txt once more, and a single click on the third row goes there.
  vim.cmd.edit(vim.fn.fnameescape(a))
  wait(3000, settled(3), "returning to a.txt a second time did not unfold its strip")
  local third = assert(picker())
  local list_win = third.list.win.win
  local row = vim.fn.screenpos(list_win, 3, 1)
  assert(row.row > 0, "the third row is not on screen")
  assert(
    FindInFile.handle_mouse({ winid = list_win, line = 3, screenrow = row.row, screencol = row.col }),
    "a press on the list was not taken"
  )
  wait(3000, function()
    return vim.api.nvim_get_current_win() == editor and vim.api.nvim_win_get_cursor(editor)[1] == 4
  end, "clicking the third match did not put the cursor on it")
  assert(picker() == third, "clicking a match closed the strip")
  assert(
    not FindInFile.handle_mouse({ winid = editor, line = 1, screenrow = 1, screencol = 1 }),
    "a press on the editor was taken as a press on the list"
  )

  -- Closing by hand takes the dock down with the picker.
  local third_dock = assert(strip().dock)
  FindInFile.close()
  wait(3000, function()
    return picker() == nil and not vim.api.nvim_win_is_valid(third_dock)
  end, "closing by hand left the dock behind")
  assert(vim.api.nvim_win_is_valid(editor), "closing the strip took the editor with it")

  -- Closing the dock window itself, as :q in it would, closes the strip.
  vim.api.nvim_set_current_win(editor)
  FindInFile.open("needle")
  wait(3000, settled(3), "reopening on a.txt did not list its matches")
  local fourth_dock = assert(strip().dock)
  vim.api.nvim_win_close(fourth_dock, true)
  wait(3000, function()
    return picker() == nil
  end, "closing the dock did not close the strip")
  assert(vim.b[buf_a].find_in_file.open == false, "closing the dock was not remembered as closing")

  -- The editor window going away takes the strip with it.
  vim.api.nvim_set_current_win(editor)
  FindInFile.open("needle")
  wait(3000, settled(3), "reopening on a.txt a second time did not list its matches")
  local last_dock = assert(strip().dock)
  -- Split from the editor, not from the strip's input where the focus went:
  -- a window split off a picker float goes down with the picker.
  vim.api.nvim_set_current_win(editor)
  vim.cmd("vsplit")
  local other = vim.api.nvim_get_current_win()
  vim.api.nvim_win_close(editor, true)
  wait(3000, function()
    return picker() == nil and strip() == nil and not vim.api.nvim_win_is_valid(last_dock)
  end, "closing the editor window did not take the strip and its dock")
  assert(vim.api.nvim_win_is_valid(other), "the remaining window was lost")
end)

vim.cmd.cd(vim.fn.fnameescape(original_cwd))
if not ok then
  io.stderr:write("FAIL: " .. tostring(test_error) .. "\n")
  os.exit(1)
end
print("find_in_file: all checks passed")
os.exit(0)
