-- Find in File: a search strip docked under the editor window, listing the
-- lines of the buffer above it that match what is typed. It is per buffer.
-- Switching the editor to another buffer folds the strip away; switching back
-- unfolds it with the same query and the same row selected. Only closing it --
-- Esc, or closing its window -- ends that, and even then the query is kept for
-- the next time it is opened on that buffer.
--
-- It is a Snacks `lines` picker drawn inside a split of our own. Snacks can
-- only open a split at an edge of the screen -- a split layout is wrapped in
-- a root box that keeps `position` and drops `relative`, so asking for one
-- under a window lands at the bottom of the screen, under the terminal. The
-- split is opened here instead, directly below the editor window, and the
-- picker is given a floating layout anchored to that split, which Snacks lays
-- out relative to a window without complaint. `preview = "main"` draws each
-- match over the editor as the list is browsed; confirming one puts the cursor
-- there and leaves the strip open for the next.
local ActivityBar = require("config.activity_bar")
local TerminalTabs = require("config.terminal_tabs")

local M = {}

local HEIGHT = 12
local STATE = "find_in_file"
-- Buffer changes arrive in bursts -- a sidebar previewing files under the
-- pointer swaps the editor's buffer on every row -- and a strip folded and
-- unfolded for each would flicker. Wait for the editor to settle first.
local SETTLE_MS = 50

-- One strip per tabpage. `main` is the editor window being watched, `buf` the
-- buffer it was last seen showing, `dock` the split under the editor and
-- `picker` the strip drawn in it -- both nil while it is folded away.
local strips = {}
local setup_done = false
local generation = 0

local function valid_win(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

local function valid_buf(buf)
  return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

local function alive(picker)
  return picker ~= nil and not picker.closed
end

-- What a buffer remembers of its strip. A buffer variable lives and dies with
-- the buffer, so nothing has to be cleaned up when one is wiped.
local function remembered(buf)
  return valid_buf(buf) and vim.b[buf][STATE] or nil
end

local function remember(buf, fields)
  if valid_buf(buf) then
    vim.b[buf][STATE] = vim.tbl_extend("force", remembered(buf) or {}, fields)
  end
end

-- Whether a window shows something worth searching: an editor window, not a
-- float, a project panel, a terminal, the dock, or one of Snacks' own.
local function searchable(win)
  if not valid_win(win) or vim.api.nvim_win_get_config(win).relative ~= "" then
    return false
  end
  if vim.w[win].snacks_win or vim.w[win].snacks_layout or vim.w[win].find_in_file_dock then
    return false
  end
  if ActivityBar.owns_window(win) or TerminalTabs.owns_window(win) then
    return false
  end
  local buftype = vim.bo[vim.api.nvim_win_get_buf(win)].buftype
  return buftype ~= "terminal" and buftype ~= "prompt"
end

-- The split the strip lives in: a fixed-height window right under the editor,
-- holding nothing of its own. The picker's windows float over it edge to edge.
local function open_dock(main)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "find_in_file_dock"
  local dock = vim.api.nvim_open_win(buf, false, {
    win = main,
    split = "below",
    height = HEIGHT,
    noautocmd = true,
  })
  vim.w[dock].find_in_file_dock = true
  vim.wo[dock].winfixheight = true
  vim.wo[dock].number = false
  vim.wo[dock].relativenumber = false
  vim.wo[dock].signcolumn = "no"
  vim.wo[dock].foldcolumn = "0"
  vim.wo[dock].cursorline = false
  vim.wo[dock].winbar = ""
  return dock
end

local function close_dock(strip)
  local dock = strip.dock
  strip.dock = nil
  if valid_win(dock) then
    pcall(vim.api.nvim_win_close, dock, true)
  end
end

local function layout(dock)
  return {
    preview = "main",
    layout = {
      box = "vertical",
      position = "float",
      relative = "win",
      win = dock,
      row = 0,
      col = 0,
      width = 0,
      height = 0,
      backdrop = false,
      border = "top",
      title = " {title} {live} {flags}",
      title_pos = "left",
      { win = "input", height = 1, border = "bottom" },
      { win = "list", border = "none" },
      -- Hidden while the preview is drawn over the editor, but the layout is
      -- expected to declare it all the same.
      { win = "preview", title = "{preview}", height = 0.4, border = "top" },
    },
  }
end

local function snapshot(picker)
  local fields = {}
  if picker.list then
    fields.cursor, fields.top = picker.list.cursor, picker.list.top
  end
  if picker.input and picker.input.filter then
    fields.pattern = picker.input.filter.pattern
  end
  return fields
end

-- Put the list back on the row it was on. Called when an unfolding strip is
-- shown, which Snacks does once its matcher has finished: the rows are all
-- there and nobody has moved among them yet. Polling for the matcher instead
-- lost both ways -- asked too early there was nothing to restore into, asked
-- too late it put the row back under a selection already made. A picker that
-- `show_delay` put up before its matcher was done is left alone.
local function restore_row(picker, saved)
  if not alive(picker) or picker:is_active() then
    return
  end
  local count = picker.list:count()
  if count > 0 then
    picker.list:view(math.min(saved.cursor or 1, count), saved.top or 1, true)
  end
end

local function open(strip, opts)
  local buf, main = strip.buf, strip.main
  local saved = remembered(buf) or {}
  local dock = open_dock(main)
  strip.dock = dock
  local picker = Snacks.picker.lines({
    buf = buf,
    title = "Find in File",
    pattern = opts.pattern or saved.pattern or "",
    enter = opts.enter == true,
    auto_close = false,
    -- A query that matches nothing is still a query being typed. The strip
    -- stays up and says so, rather than vanishing under the reader's hands.
    show_empty = true,
    -- Confirming a row puts the cursor on it and hands focus to the editor.
    -- The strip stays for the next one.
    jump = { match = true, close = false, reuse_win = false },
    layout = layout(dock),
    win = {
      input = {
        keys = {
          -- Esc closes from Insert mode too. This is a find box, not a prompt
          -- with a Normal mode worth stopping in on the way out.
          ["<Esc>"] = { "cancel", mode = { "n", "i" } },
        },
      },
    },
    -- Only an unfolding strip goes back to its row. One opened by Ctrl+F is
    -- a fresh search, and starts at the top.
    on_show = function(shown)
      if strip.picker == shown and not opts.enter then
        restore_row(shown, saved)
      end
    end,
    on_close = function(closing)
      if strip.picker ~= closing then
        return
      end
      local reason = strip.closing or "user"
      strip.closing, strip.picker = nil, nil
      local fields = snapshot(closing)
      -- Folded away for another buffer, the strip is still open as far as
      -- this buffer is concerned. Closed by hand, it is not. A window going
      -- away says nothing either way.
      if reason ~= "gone" then
        fields.open = reason == "switch"
      end
      remember(buf, fields)
      -- The picker takes its windows down on the next tick. The split they
      -- float over goes after them, not before.
      vim.schedule(function()
        vim.schedule(function()
          if strip.dock == dock then
            close_dock(strip)
          end
        end)
      end)
    end,
  })
  if not picker then
    close_dock(strip)
    return
  end
  strip.picker = picker
  picker.main = main
  -- Snacks shows a picker on the tick after its results arrive. Keys typed
  -- before then go to the window that still has the focus -- the editor, in
  -- Normal mode, where a query like `dd` is a command. When the strip is
  -- opened to be typed into, it takes the focus before this returns.
  if opts.enter then
    picker:show()
  end
  for _, window in pairs({ picker.input.win, picker.list.win }) do
    ActivityBar.disable_selection_gestures(window.buf)
  end
  remember(buf, { open = true })
end

local function close(strip, reason)
  local picker = strip.picker
  if not alive(picker) then
    strip.picker = nil
    close_dock(strip)
    return
  end
  strip.closing = reason
  picker:close()
end

-- A folded strip's windows go over the next two ticks: the picker takes its
-- floats down on the first and the dock follows on the second. Open the next
-- one after both, or two splits stack under the editor.
local function open_after_fold(tab, strip, opts)
  local main, buf = strip.main, strip.buf
  vim.schedule(function()
    vim.schedule(function()
      local same = strips[tab] == strip and strip.main == main and strip.buf == buf
      if same and not alive(strip.picker) and not strip.dock then
        open(strip, opts)
      end
    end)
  end)
end

-- Bring the strip in line with what its editor window shows now.
local function sync(tab)
  local strip = strips[tab]
  if not strip then
    return
  end
  if not valid_win(strip.main) then
    close(strip, "gone")
    strips[tab] = nil
    return
  end
  local shown = vim.api.nvim_win_get_buf(strip.main)
  if shown == strip.buf then
    return
  end
  close(strip, "switch")
  strip.buf = shown
  local saved = remembered(shown)
  if saved and saved.open and searchable(strip.main) then
    open_after_fold(tab, strip, { enter = false })
  end
end

local function schedule_sync()
  generation = generation + 1
  local current = generation
  vim.defer_fn(function()
    if current ~= generation then
      return
    end
    for tab in pairs(strips) do
      if vim.api.nvim_tabpage_is_valid(tab) then
        sync(tab)
      else
        strips[tab] = nil
      end
    end
  end, SETTLE_MS)
end

-- A window of ours closing is not something to wait out: the editor going
-- away leaves a split that the panels could mistake for the editor, and the
-- split going away leaves floats with nothing to hang from.
local function on_win_closed(win)
  for tab, strip in pairs(strips) do
    if win == strip.main then
      close(strip, "gone")
      strips[tab] = nil
    elseif win == strip.dock then
      strip.dock = nil
      close(strip, "user")
    end
  end
end

-- The floats are sized from the dock when the layout is computed. Snacks lays
-- them out again when the dock moves -- it watches where its root float sits
-- on screen -- but not when the dock only changes width, as it does when a
-- window opens to the right of the editor column.
local function on_win_resized(windows)
  for _, strip in pairs(strips) do
    local picker = strip.picker
    if strip.dock and alive(picker) and picker.shown and vim.tbl_contains(windows, strip.dock) then
      picker.layout:update()
    end
  end
end

--- Open the strip under the current window, or focus it if it is already
--- there. `pattern` replaces the query when given.
function M.open(pattern)
  local tab = vim.api.nvim_get_current_tabpage()
  local win = vim.api.nvim_get_current_win()
  local strip = strips[tab]
  if strip and alive(strip.picker) then
    local picker = strip.picker
    local inside = win == picker.input.win.win or win == picker.list.win.win
    if (inside or win == strip.main) and vim.api.nvim_win_get_buf(strip.main) == strip.buf then
      if pattern and pattern ~= "" then
        picker.input:set(pattern)
      end
      picker:focus("input")
      return
    end
  end
  if not searchable(win) then
    return
  end
  -- One strip per tab: whatever window it hung under before, it hangs under
  -- this one now.
  strip = strip or {}
  strips[tab] = strip
  local folding = alive(strip.picker)
  close(strip, "switch")
  strip.main, strip.buf = win, vim.api.nvim_win_get_buf(win)
  local opts = { pattern = pattern, enter = true }
  if folding then
    open_after_fold(tab, strip, opts)
  else
    open(strip, opts)
  end
end

--- Open the strip with the Visual selection as the query, when it is a single
--- line. A selection spanning lines is not a query; the last one is kept.
function M.open_selection()
  local lines = vim.fn.getregion(vim.fn.getpos("v"), vim.fn.getpos("."), { type = vim.fn.mode() })
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  M.open(#lines == 1 and lines[1] or nil)
end

--- Close the strip in the current tab, the way Esc would.
function M.close()
  local strip = strips[vim.api.nvim_get_current_tabpage()]
  if strip then
    close(strip, "user")
  end
end

--- A press on a row of the strip's list confirms that row. Called from the
--- global mouse chain, where a first click on an unfocused window can be seen.
function M.handle_mouse(mouse)
  local win = mouse and tonumber(mouse.winid)
  if not valid_win(win) then
    return false
  end
  local strip = strips[vim.api.nvim_win_get_tabpage(win)]
  if not strip or not alive(strip.picker) then
    return false
  end
  return ActivityBar.click_picker_list(strip.picker, mouse)
end

function M.setup()
  if setup_done then
    return
  end
  setup_done = true
  local group = vim.api.nvim_create_augroup("find_in_file", { clear = true })
  vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, {
    group = group,
    callback = schedule_sync,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(event)
      on_win_closed(tonumber(event.match))
      schedule_sync()
    end,
  })
  vim.api.nvim_create_autocmd("WinResized", {
    group = group,
    callback = function()
      on_win_resized(vim.v.event.windows or {})
    end,
  })
end

M._strips = strips
M._searchable = searchable
M._resized = on_win_resized

return M
