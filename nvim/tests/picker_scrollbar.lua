local ActivityBar = require("config.activity_bar")
local Scrollbar = require("config.picker_scrollbar")

local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/src/many", "p")
assert(vim.fn.writefile({ "x" }, root .. "/src/a.lua") == 0)
for index = 1, 60 do
  assert(vim.fn.writefile({ "x" }, ("%s/src/many/f%03d.txt"):format(root, index)) == 0)
end
local function git(args)
  local command = { "git", "-C", root }
  vim.list_extend(command, args)
  local result = vim.system(command, { text = true }):wait()
  assert(result.code == 0, result.stderr)
end
git({ "init", "-q" })
git({ "config", "user.name", "t" })
git({ "config", "user.email", "t@example.invalid" })
git({ "add", "-A" })
git({ "commit", "-qm", "init" })

local original_cwd = vim.fn.getcwd(0)
local original_columns = vim.o.columns

local function sidebar_bar()
  for list_win, bar in pairs(Scrollbar._bars) do
    if vim.api.nvim_win_is_valid(list_win) and vim.api.nvim_win_is_valid(bar.win) then
      return vim.api.nvim_win_get_config(bar.win)
    end
  end
end

local ok, test_error = pcall(function()
  vim.cmd.cd(vim.fn.fnameescape(root))
  vim.o.columns = 160
  ActivityBar.setup()
  Scrollbar.setup()
  assert(Scrollbar._patched(), "the picker scrollbar was never hooked in")

  local state = ActivityBar.open("explorer", { focus = false })
  assert(
    vim.wait(5000, function()
      return state.content and state.content.kind == "explorer" and ActivityBar._content_root(state.content)
    end),
    "the Explorer did not become ready"
  )
  local picker = state.content.picker
  vim.wait(2000, function()
    return picker.list:count() > 0
  end)

  -- A list that fits its window earns no bar.
  assert(sidebar_bar() == nil, "a scrollbar appeared although the list does not overflow")

  require("snacks.explorer.tree"):open(root .. "/src/many")
  picker:find()
  assert(
    vim.wait(5000, function()
      return picker.list:count() > 60
    end),
    "the Explorer never listed the expanded directory"
  )
  assert(
    vim.wait(5000, function()
      return sidebar_bar() ~= nil
    end),
    "the overflowing Explorer list never got a scrollbar"
  )
  local bar = sidebar_bar()
  local height = vim.api.nvim_win_get_height(picker.list.win.win)
  local count = picker.list:count()
  local expected_height = math.max(1, math.floor(height * height / count + 0.5))
  assert(
    bar.height == expected_height,
    ("the bar is %d rows tall for %d items in %d rows; expected %d"):format(bar.height, count, height, expected_height)
  )
  assert(bar.row == 0, "the bar does not start at the top for an unscrolled list")

  -- Virtual scrolling must move the bar even though the buffer never scrolls.
  picker.list:scroll(30, true, true)
  assert(
    vim.wait(2000, function()
      local current = sidebar_bar()
      return current ~= nil and current.row > 0
    end),
    "virtually scrolling the list did not move the bar"
  )

  -- Dragging: a press on the handle arms the gesture, drags reposition the
  -- list by real screen rows, release disarms.
  picker.list:scroll(1, true, true)
  vim.wait(300)
  local current_bar, current_list_win
  for list_win, entry in pairs(Scrollbar._bars) do
    if vim.api.nvim_win_is_valid(list_win) and vim.api.nvim_win_is_valid(entry.win) then
      current_bar, current_list_win = entry, list_win
    end
  end
  assert(current_bar, "no bar to drag")
  local bar_position = vim.fn.win_screenpos(current_bar.win)
  local press = { screenrow = bar_position[1], screencol = bar_position[2] }
  assert(Scrollbar.handle_mouse(press), "a press on the handle was not consumed")
  local top_before = picker.list.top
  assert(
    Scrollbar.handle_drag({ screenrow = bar_position[1] + 10, screencol = bar_position[2] }),
    "a drag while armed was not consumed"
  )
  assert(
    vim.wait(3000, function()
      return picker.list.top > top_before
    end),
    "dragging the handle did not scroll the list"
  )
  assert(Scrollbar.handle_release(), "the release was not consumed")
  assert(
    not Scrollbar.handle_drag({ screenrow = bar_position[1], screencol = bar_position[2] }),
    "a drag leaked past release"
  )

  -- Everything above calls the handlers directly, which says nothing about
  -- whether a real drag can reach them. It could not: the panels used to map
  -- <LeftDrag> and <LeftRelease> buffer-locally to <Nop> so that dragging
  -- would not start a selection, and a buffer-local mapping wins over a global
  -- one -- so with a panel focused, which is the normal case, the press armed
  -- a drag that then never moved and never ended. Resolve the keys the way
  -- Neovim will, from inside the panel.
  assert(vim.api.nvim_win_is_valid(current_list_win), "the list window closed")
  vim.api.nvim_set_current_win(current_list_win)
  for _, key in ipairs({ "<LeftDrag>", "<LeftRelease>" }) do
    local mapping = vim.fn.maparg(key, "n", false, true)
    assert(
      mapping.buffer == 0,
      ("%s resolves to a buffer-local mapping inside a panel, shadowing the scrollbar"):format(key)
    )
    assert(mapping.callback, ("%s is not routed through a handler"):format(key))
    assert(mapping.rhs ~= "<Nop>", ("%s is swallowed before the scrollbar sees it"):format(key))
  end

  -- ...and that the mapping it does resolve to actually offers the event to
  -- the scrollbar, rather than swallowing it as panel text selection.
  local reached = {}
  local real_drag, real_release = Scrollbar.handle_drag, Scrollbar.handle_release
  Scrollbar.handle_drag = function()
    reached.drag = true
    return true
  end
  Scrollbar.handle_release = function()
    reached.release = true
    return true
  end
  local routed = pcall(function()
    for key, name in pairs({ ["<LeftDrag>"] = "drag", ["<LeftRelease>"] = "release" }) do
      local mapping = vim.fn.maparg(key, "n", false, true)
      assert(mapping.callback() == "", ("%s was not swallowed once the scrollbar consumed it"):format(key))
      assert(reached[name], ("%s never reached the scrollbar"):format(key))
    end
  end)
  Scrollbar.handle_drag, Scrollbar.handle_release = real_drag, real_release
  assert(routed, "the drag gestures are not routed to the scrollbar")

  -- The bar dies with its view.
  ActivityBar.open("git", { focus = false })
  assert(
    vim.wait(5000, function()
      return sidebar_bar() == nil
    end),
    "the scrollbar outlived its picker list"
  )

  -- Terminal windows: scrollview refuses them upstream, so this module owns
  -- their bar too, driven by the window's real topline.
  vim.cmd("botright 10new")
  local term_win = vim.api.nvim_get_current_win()
  vim.fn.jobstart({ "seq", "1", "300" }, { term = true })
  assert(
    vim.wait(5000, function()
      return vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(term_win)) > 100
    end),
    "the test terminal never produced its output"
  )
  local function terminal_bar()
    local bar = Scrollbar._bars[term_win]
    if bar and vim.api.nvim_win_is_valid(bar.win) then
      return vim.api.nvim_win_get_config(bar.win)
    end
  end
  assert(
    vim.wait(5000, function()
      Scrollbar._refresh_terminals()
      return terminal_bar() ~= nil
    end),
    "the overflowing terminal never got a scrollbar"
  )
  vim.api.nvim_win_call(term_win, function()
    vim.cmd("normal! gg")
  end)
  assert(
    vim.wait(3000, function()
      Scrollbar._refresh_terminals()
      local bar = terminal_bar()
      return bar ~= nil and bar.row == 0
    end),
    "scrolling the terminal to the top did not move the bar there"
  )
  vim.api.nvim_win_call(term_win, function()
    vim.cmd("normal! G")
  end)
  assert(
    vim.wait(3000, function()
      Scrollbar._refresh_terminals()
      local bar = terminal_bar()
      return bar ~= nil and bar.row > 0
    end),
    "scrolling the terminal back down did not move the bar"
  )
  -- Dragging the terminal bar scrolls the real window and holds after
  -- release (the cursor is moved into the view so it cannot snap back).
  local term_bar = terminal_bar()
  assert(term_bar, "no terminal bar to drag")
  local term_bar_position
  for target, entry in pairs(Scrollbar._bars) do
    if target == term_win and vim.api.nvim_win_is_valid(entry.win) then
      term_bar_position = vim.fn.win_screenpos(entry.win)
    end
  end
  assert(term_bar_position, "could not locate the terminal bar on screen")
  assert(
    Scrollbar.handle_mouse({ screenrow = term_bar_position[1], screencol = term_bar_position[2] }),
    "a press on the terminal handle was not consumed"
  )
  local target_row = vim.fn.win_screenpos(term_win)[1]
  Scrollbar.handle_drag({ screenrow = target_row, screencol = term_bar_position[2] })
  assert(
    vim.wait(3000, function()
      return vim.fn.line("w0", term_win) < 100
    end),
    "dragging the terminal handle did not scroll the terminal"
  )
  Scrollbar.handle_release()
  local settled = vim.fn.line("w0", term_win)
  vim.wait(500)
  assert(vim.fn.line("w0", term_win) == settled, "the terminal view snapped back after the drag")

  vim.api.nvim_win_close(term_win, true)
  assert(
    vim.wait(3000, function()
      return terminal_bar() == nil
    end),
    "the terminal scrollbar outlived its window"
  )
end)

pcall(ActivityBar.close)
vim.o.columns = original_columns
vim.cmd.cd(vim.fn.fnameescape(original_cwd))
vim.fn.delete(root, "rf")
assert(ok, test_error)

print("picker-scrollbar-ok")
