local ActivityBar = require("config.activity_bar")
local TerminalTabs = require("config.terminal_tabs")

local root = vim.fn.tempname()
local relative = "src/file.txt"
local file = vim.fs.joinpath(root, relative)
vim.fn.mkdir(vim.fs.dirname(file), "p")
assert(vim.fn.writefile({ "alpha beta" }, file) == 0)

local function git(args)
  local command = { "git", "-C", root }
  vim.list_extend(command, args)
  local result = vim.system(command, { text = true }):wait()
  assert(result.code == 0, result.stderr)
end

-- A picker list only scrolls once it holds more entries than it has rows, and
-- the click handler this file guards only misbehaved after a scroll.
for index = 1, 60 do
  assert(vim.fn.writefile({ "" }, vim.fs.joinpath(root, ("entry-%02d.txt"):format(index))) == 0)
end

git({ "init", "-q" })
git({ "config", "user.name", "Activity Bar Test" })
git({ "config", "user.email", "activity-bar@example.invalid" })
git({ "add", relative })
git({ "commit", "-qm", "initial" })

local original_cwd = vim.fn.getcwd(0)
-- Headless Neovim has no UI: widening 'columns' is honoured, but raising
-- 'lines' only inflates 'cmdheight' once the screen is recomputed.
local original_columns = vim.o.columns
-- LazyVim turns 'list' on globally; every panel has to opt out of it itself.
local original_list = vim.o.list

local function open(view)
  local state = ActivityBar.open(view, { focus = false })
  assert(
    vim.wait(5000, function()
      return state.content and state.content.kind == view and ActivityBar._content_root(state.content)
    end),
    ("Activity Bar %s view did not become ready"):format(view)
  )
  return state
end

local function view_row(view)
  for index, item in ipairs(ActivityBar._views) do
    if item.name == view then
      return index
    end
  end
end

local ok, test_error = pcall(function()
  vim.cmd.cd(vim.fn.fnameescape(root))
  vim.cmd.edit(vim.fn.fnameescape(file))
  vim.o.columns = 160
  vim.o.list = true
  ActivityBar.setup()

  local state = open("explorer")
  local activity_win = state.activity.win
  TerminalTabs.open(root, false)
  assert(
    vim.wait(5000, function()
      local group = TerminalTabs._groups[TerminalTabs._normalize_root(root)]
      return group and group.active and group.active.terminal:win_valid()
    end),
    "the project terminal did not become ready"
  )
  ActivityBar.reflow()

  -- Panel chrome must not render 'listchars'.
  assert(vim.wo[activity_win].list == false, "the Activity Bar column still renders 'listchars'")

  -- The Activity Bar column must never become a host for a file buffer.
  if vim.fn.exists("&winfixbuf") == 1 then
    assert(vim.wo[activity_win].winfixbuf == true, "the Activity Bar column is not pinned to its buffer")
    local hijacked = vim.api.nvim_win_call(activity_win, function()
      return (pcall(vim.cmd.edit, vim.fn.fnameescape(file)))
    end)
    assert(not hijacked, "a file could be edited into the Activity Bar column")
    assert(
      vim.bo[vim.api.nvim_win_get_buf(activity_win)].filetype == "activity_bar",
      "the Activity Bar column lost its own buffer"
    )
  end

  -- Panel scratch buffers must never appear as buffer tabs. `:vnew` creates a
  -- listed buffer, so this has to be turned off explicitly.
  assert(
    vim.bo[vim.api.nvim_win_get_buf(activity_win)].buflisted == false,
    "the Activity Bar buffer is listed and shows up as a buffer tab"
  )

  -- Neovim's tabline spans the whole screen, so Bufferline has to reserve the
  -- Activity Bar and the sidebar for buffer tabs to start above the editor.
  require("lazy").load({ plugins = { "bufferline.nvim" } })
  local bufferline_offsets = require("bufferline.config").options.offsets or {}
  local has_entry = false
  for _, offset in ipairs(bufferline_offsets) do
    has_entry = has_entry or offset.filetype == "activity_bar"
  end
  assert(has_entry, "Bufferline has no Activity Bar offset entry to size")
  local function reserved_width()
    ActivityBar._sync_tabline_offset()
    return require("bufferline.offset").get().total_size
  end
  local function editor_column()
    return vim.api.nvim_win_get_position(assert(ActivityBar.editor_window()))[2]
  end
  assert(
    reserved_width() == editor_column(),
    ("the tabline reserves %d columns but the editor starts at %d"):format(reserved_width(), editor_column())
  )
  ActivityBar.close()
  assert(
    vim.wait(5000, function()
      return ActivityBar.current().collapsed and not ActivityBar._content_root(ActivityBar.current().content)
    end),
    "the sidebar did not collapse"
  )
  assert(reserved_width() == editor_column(), "the tabline still reserves the sidebar after it was collapsed")
  open("explorer")
  assert(reserved_width() == editor_column(), "the tabline did not follow the sidebar being reopened")

  -- A terminal the user resized must survive switching sidebar views.
  local terminal_win = TerminalTabs._groups[TerminalTabs._normalize_root(root)].active.terminal.win
  local editor_win = assert(ActivityBar.editor_window())
  -- Stay inside the bounds the reflow enforces, so only the "keep what the
  -- user set" behaviour is under test.
  local total = vim.api.nvim_win_get_height(terminal_win) + vim.api.nvim_win_get_height(editor_win)
  local resized = math.max(6, math.min(vim.api.nvim_win_get_height(terminal_win) + 2, total - 8))
  vim.wo[terminal_win].winfixheight = false
  vim.api.nvim_win_set_height(terminal_win, resized)
  vim.wo[terminal_win].winfixheight = true
  assert(vim.api.nvim_win_get_height(terminal_win) == resized, "the test could not resize the terminal")
  open("search")
  open("explorer")
  assert(
    vim.api.nvim_win_get_height(terminal_win) == resized,
    ("switching views reset the terminal height from %d to %d"):format(
      resized,
      vim.api.nvim_win_get_height(terminal_win)
    )
  )

  -- A sidebar the user widened must survive the next reflow.
  local sidebar = ActivityBar._content_root(ActivityBar.current().content)
  vim.wo[sidebar].winfixwidth = false
  vim.api.nvim_win_set_width(sidebar, 62)
  vim.wo[sidebar].winfixwidth = true
  ActivityBar.reflow()
  assert(
    vim.api.nvim_win_get_width(ActivityBar._content_root(ActivityBar.current().content)) == 62,
    "a manually resized sidebar was reset by the next reflow"
  )

  -- The cursorline and the active-view highlight must stay on the same row.
  for _, view in ipairs({ "search", "explorer" }) do
    local opened = open(view)
    assert(
      vim.api.nvim_win_get_cursor(opened.activity.win)[1] == view_row(view),
      ("the Activity Bar cursor does not follow the %s view"):format(view)
    )
  end

  -- <Esc> must leave Insert mode in the Search prompt without closing it.
  state = open("search")
  local input_buf = state.content.picker.input.win.buf
  local insert_escape
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(input_buf, "i")) do
    if map.lhs == "<Esc>" then
      insert_escape = map
    end
  end
  assert(insert_escape, "the Search prompt has no Insert-mode <Esc> mapping")
  assert(
    (insert_escape.rhs or ""):lower():find("c%-\\"),
    "Insert-mode <Esc> in the Search prompt does not return to Normal mode"
  )

  -- toggle() must not throw when no state can be created for the given tab.
  assert(pcall(ActivityBar.toggle, "explorer", { tab = 999999 }), "toggle() errored for a tab with no Activity Bar")

  -- The Git panel is chrome too, and its row is the one the bar highlights.
  state = open("git")
  assert(vim.wo[ActivityBar._content_root(state.content)].list == false, "the Git panel still renders 'listchars'")
  assert(
    vim.api.nvim_win_get_cursor(state.activity.win)[1] == view_row("git"),
    "the Activity Bar cursor does not follow the git view"
  )

  -- The Git panel's buffer-local <LeftMouse> mapping shadows the global one,
  -- so it has to offer clicks on the Activity Bar to the Activity Bar. Without
  -- that, switching views from the Git panel needed a second click.
  local panel_buf = vim.api.nvim_win_get_buf(ActivityBar._content_root(state.content))
  local panel_click
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(panel_buf, "n")) do
    if map.lhs == "<LeftMouse>" and map.callback then
      panel_click = map.callback
    end
  end
  assert(panel_click, "the Git panel has no buffer-local <LeftMouse> mapping")
  local explorer_row = view_row("explorer")
  local screen = vim.fn.screenpos(state.activity.win, explorer_row, 1)
  local original_getmousepos = vim.fn.getmousepos
  vim.fn.getmousepos = function()
    return {
      winid = state.activity.win,
      line = explorer_row,
      column = 1,
      screenrow = screen.row,
      screencol = screen.col,
      winrow = explorer_row,
      wincol = 1,
    }
  end
  local handled, consumed = pcall(panel_click)
  vim.fn.getmousepos = original_getmousepos
  assert(handled, "the Git panel's <LeftMouse> mapping errored on an Activity Bar click: " .. tostring(consumed))
  assert(consumed == "", "the Git panel passed an Activity Bar click through instead of acting on it")
  assert(
    vim.wait(5000, function()
      local current = ActivityBar.current()
      return current and current.view == "explorer" and ActivityBar._content_root(current.content)
    end),
    ("one click on an Activity Bar icon did not switch views from the Git panel (view=%s)"):format(
      tostring((ActivityBar.current() or {}).view)
    )
  )
  state = assert(ActivityBar.current())

  -- Snacks binds only <2-LeftMouse> on a picker list, so a single click on a
  -- folder did nothing. The handler must live in the global mouse chain: a
  -- buffer-local mapping only applies once the sidebar already has focus, so
  -- the first click on an unfocused sidebar was swallowed as a focus change.
  state = open("explorer")
  local list = state.content.picker.list
  assert(
    vim.wait(5000, function()
      return list:count() > 0
    end),
    "the Explorer list stayed empty"
  )
  local folder_row
  for index = 1, list:count() do
    local item = list:get(index)
    if item and item.dir and index > 1 then
      folder_row = index
      break
    end
  end
  assert(folder_row, "no collapsed folder to click")
  local before = list:count()
  local screen = vim.fn.screenpos(list.win.win, folder_row, 1)
  -- Click from the editor, i.e. with the sidebar unfocused.
  vim.api.nvim_set_current_win(assert(ActivityBar.editor_window()))
  assert(
    ActivityBar._handle_list_click({
      winid = list.win.win,
      line = folder_row,
      screenrow = screen.row,
      screencol = screen.col,
    }),
    "a single click on a folder was not handled"
  )
  assert(
    vim.wait(5000, function()
      return list:count() ~= before
    end),
    "a single click on a folder did not toggle it"
  )

  -- The list buffer holds only the entries on screen: scrolling rewrites it
  -- from `list.top` rather than moving the view. A click's buffer line is an
  -- offset into that window, not an item index, so taking it for one opened
  -- whichever file had been on that line before the wheel was used.
  assert(
    vim.wait(5000, function()
      return list:count() > list:height()
    end),
    "the Explorer never listed more entries than it has rows"
  )
  -- A remembered list position is re-applied by the next render, and that
  -- render happens inside view(), so ask for the next page until it sticks.
  assert(
    vim.wait(5000, function()
      local page = list:height() + 1
      list:view(page, page, true)
      return list.top > 1
    end),
    "the Explorer list did not scroll"
  )
  local file_row, target
  for row = list:height(), 1, -1 do
    local candidate = list:get(list:row2idx(row))
    if candidate and not candidate.dir and candidate.file then
      file_row, target = row, candidate
      break
    end
  end
  assert(file_row, "no file was on screen after scrolling the Explorer")
  local function editor_file()
    local editor = ActivityBar.editor_window()
    if not editor then
      return ""
    end
    return vim.fs.normalize(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(editor)))
  end
  local wanted = vim.fs.normalize(target.file)
  assert(editor_file() ~= wanted, "the file to click was already open")
  local hit = vim.fn.screenpos(list.win.win, file_row, 1)
  vim.api.nvim_set_current_win(assert(ActivityBar.editor_window()))
  assert(
    ActivityBar._handle_list_click({
      winid = list.win.win,
      line = file_row,
      screenrow = hit.row,
      screencol = hit.col,
    }),
    "a click on a scrolled Explorer was not handled"
  )
  assert(
    vim.wait(5000, function()
      return editor_file() == wanted
    end),
    ("clicking the row showing %s opened %s"):format(wanted, editor_file())
  )

  -- Dragging in a panel used to start a Visual selection over the file tree.
  -- Assert what happens, not how: these gestures cannot be neutralised with a
  -- buffer-local mapping, because that would also win over the sidebar
  -- scrollbar's drag handling. They are swallowed by whichever global mapping
  -- is in force, and several modules install one, each shadowing the last in
  -- whatever order the panels happened to be opened.
  local real_getmousepos = vim.fn.getmousepos
  local function swallowed(win, key)
    vim.fn.getmousepos = function()
      return { winid = win, screenrow = 1, screencol = 1, winrow = 1, wincol = 1, line = 1, column = 1 }
    end
    local mapping = vim.fn.maparg(key, "n", false, true)
    local produced = mapping.callback and mapping.callback() or mapping.rhs
    vim.fn.getmousepos = real_getmousepos
    return produced == ""
  end

  local function assert_panels_swallow(picker, when)
    for _, window in ipairs({ picker.list.win, picker.input.win }) do
      for _, key in ipairs({ "<LeftDrag>", "<LeftRelease>" }) do
        assert(swallowed(window.win, key), ("%s selects panel text %s"):format(key, when))
      end
    end
  end

  assert_panels_swallow(state.content.picker, "in the Explorer")

  -- The Git panel installs global drag mappings of its own and never removes
  -- them, so from the first time it is opened it answers for every panel,
  -- including the two it knows nothing about.
  ActivityBar.open("git", { focus = false })
  assert(
    vim.wait(10000, function()
      return require("config.git_panel").current() ~= nil
    end),
    "the Git panel never opened"
  )
  state = ActivityBar.open("explorer", { focus = false })
  assert(
    vim.wait(10000, function()
      local picker = state.content and state.content.picker
      return picker ~= nil and picker.list ~= nil and picker.list.win:valid()
    end),
    "the Explorer never came back"
  )
  assert_panels_swallow(state.content.picker, "once the Git panel has been opened")

  -- Dragging the sidebar border is the only way a user can resize it, and
  -- dragging it back leftwards takes the pointer over the panel, where the rule
  -- above swallows the drag. The sidebar could be widened and never narrowed.
  -- A gesture that starts anywhere but on buffer text -- a separator, a status
  -- line -- is a resize, and belongs to Neovim until the button comes up.
  local sidebar_win = assert(ActivityBar._content_root(ActivityBar.current().content))
  local function deliver(key, win, line)
    local mapping = vim.fn.maparg(key, "n", false, true)
    assert(type(mapping.callback) == "function", key .. " has no handler")
    vim.fn.getmousepos = function()
      return { winid = win, screenrow = 1, screencol = 1, winrow = 1, wincol = 1, line = line, column = 1 }
    end
    local produced = mapping.callback()
    vim.fn.getmousepos = real_getmousepos
    return produced
  end

  -- A press on the border, then a drag that has moved over the panel.
  deliver("<LeftMouse>", sidebar_win, 0)
  assert(deliver("<LeftDrag>", sidebar_win, 1) ~= "", "a drag that began on the border was swallowed by the panel")
  assert(deliver("<LeftRelease>", sidebar_win, 1) ~= "", "the release that ends a border drag was swallowed")

  -- A press that lands on text starts nothing of the sort, and the panel goes
  -- back to swallowing drags so they cannot select its contents.
  deliver("<LeftMouse>", assert(ActivityBar.editor_window()), 1)
  assert(deliver("<LeftDrag>", sidebar_win, 1) == "", "a drag inside the panel can select its text again")

  -- Losing the Activity Bar column must take its sidebar down with it.
  local tab = state.tab
  vim.api.nvim_win_close(state.activity.win, true)
  assert(
    vim.wait(5000, function()
      return ActivityBar._states[tab] == nil
    end),
    "closing the Activity Bar column left its state behind"
  )
end)

pcall(ActivityBar.close)
pcall(TerminalTabs.close_all, root)
vim.o.list = original_list
vim.o.columns = original_columns
vim.cmd.cd(vim.fn.fnameescape(original_cwd))
vim.fn.delete(root, "rf")
assert(ok, test_error)

print("activity-bar-regressions-ok")
