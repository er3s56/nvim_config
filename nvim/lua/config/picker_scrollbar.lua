-- Working scrollbars for the panels scrollview cannot serve.
--
-- Snacks picker lists: scrollview derives its bar from buffer lines, and
-- Snacks virtualizes its lists -- the buffer only ever holds the visible
-- rows (measured: 66 items, 40 buffer lines), so a buffer-derived bar is
-- permanently full-height. The picker itself knows the truth: `list.top`
-- and `list:count()` describe the virtual scroll state, so a one-column
-- float on the list's right edge can mirror it exactly. It updates inside
-- `List:render`, the point every scroll and refresh path converges on
-- (scrolling calls render directly and bypasses update), so the bar moves
-- in the same tick as the content.
--
-- Terminal windows: scrollview refuses them outright (`wininfo.terminal`
-- is rejected upstream). A terminal buffer is ordinary, though -- output
-- lines plus the screen -- so the same float driven by the window's real
-- topline works, refreshed on scrolling and on output.
local WinOptions = require("config.win_options")

local M = {}

-- list window id -> { win = bar float, buf = bar buffer }
local bars = {}
local patched = false

local function drop_bar(list_win)
  local bar = bars[list_win]
  bars[list_win] = nil
  if bar and bar.win and not vim.api.nvim_win_is_valid(bar.win) then
    return
  end
  if bar and vim.api.nvim_win_is_valid(bar.win) then
    pcall(vim.api.nvim_win_close, bar.win, true)
  end
end

local function sweep()
  for list_win, bar in pairs(bars) do
    if not vim.api.nvim_win_is_valid(list_win) or not vim.api.nvim_win_is_valid(bar.win) then
      drop_bar(list_win)
    end
  end
end

-- Shared float placement for any window-shaped source.
local function place_bar(target_win, total, top)
  local height = vim.api.nvim_win_get_height(target_win)
  if total <= height or height < 2 then
    drop_bar(target_win)
    return
  end
  local bar_height = math.max(1, math.floor(height * height / total + 0.5))
  local track = height - bar_height
  top = math.max(1, math.min(top or 1, total))
  local row = math.floor(track * (top - 1) / math.max(1, total - height) + 0.5)
  row = math.max(0, math.min(row, track))
  local col = math.max(0, vim.api.nvim_win_get_width(target_win) - 1)
  local bar = bars[target_win]
  if bar and vim.api.nvim_win_is_valid(bar.win) then
    pcall(vim.api.nvim_win_set_config, bar.win, {
      relative = "win",
      win = target_win,
      row = row,
      col = col,
      width = 1,
      height = bar_height,
    })
    return
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "picker_scrollbar"
  local ok, win = pcall(vim.api.nvim_open_win, buf, false, {
    relative = "win",
    win = target_win,
    row = row,
    col = col,
    width = 1,
    height = bar_height,
    style = "minimal",
    focusable = false,
    zindex = 60,
  })
  if not ok or not vim.api.nvim_win_is_valid(win) then
    return
  end
  WinOptions.set(win, { winhighlight = "Normal:ScrollView,EndOfBuffer:ScrollView" })
  bars[target_win] = { win = win, buf = buf }
end

local function refresh_terminal(win)
  if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_config(win).relative ~= "" then
    return
  end
  local buf = vim.api.nvim_win_get_buf(win)
  if vim.bo[buf].buftype ~= "terminal" then
    drop_bar(win)
    return
  end
  place_bar(win, vim.api.nvim_buf_line_count(buf), vim.fn.line("w0", win))
end

local function refresh_terminals()
  sweep()
  -- The list is taken once and walked, and the walk closes windows: a bar
  -- belonging to a window that stopped being a terminal is dropped, and its
  -- float is in the very list being walked. An id read later in the same loop
  -- can therefore be gone, which is what the single-window version below has
  -- always checked for.
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if
      vim.api.nvim_win_is_valid(win)
      and vim.api.nvim_win_get_config(win).relative == ""
      and vim.bo[vim.api.nvim_win_get_buf(win)].buftype == "terminal"
    then
      refresh_terminal(win)
    end
  end
end

local terminal_refresh_queued = false
local function queue_terminal_refresh()
  if terminal_refresh_queued then
    return
  end
  terminal_refresh_queued = true
  vim.schedule(function()
    terminal_refresh_queued = false
    refresh_terminals()
  end)
end

local function refresh(list)
  sweep()
  local list_win = list.win and list.win.win
  if list_win and bars[list_win] then
    bars[list_win].list = list
  end
  if not list_win or not vim.api.nvim_win_is_valid(list_win) then
    return
  end
  -- The list window is itself a float anchored to the layout's root box.
  -- Sidebar pickers root that box in a split; ordinary floating pickers
  -- root it in an editor-anchored float and keep their own look.
  local config = vim.api.nvim_win_get_config(list_win)
  local parent = config.relative == "win" and config.win or nil
  if config.relative ~= "" then
    if not parent or not vim.api.nvim_win_is_valid(parent) then
      return
    end
    if vim.api.nvim_win_get_config(parent).relative ~= "" then
      return
    end
  end
  place_bar(list_win, list:count(), list.top or 1)
  if bars[list_win] then
    bars[list_win].list = list
  end
end

-- Scroll geometry for a bar's target window.
local function metrics(target_win)
  local bar = bars[target_win]
  if not bar or not vim.api.nvim_win_is_valid(target_win) then
    return
  end
  local height = vim.api.nvim_win_get_height(target_win)
  local total
  if bar.list then
    total = bar.list:count()
  else
    total = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(target_win))
  end
  if total <= height then
    return
  end
  local bar_height = math.max(1, math.floor(height * height / total + 0.5))
  return { height = height, total = total, track = height - bar_height, bar_height = bar_height }
end

-- One positioning step: put the top of the handle at `bar_row` (0-based).
local function scroll_to(target_win, bar_row)
  local bar = bars[target_win]
  local m = metrics(target_win)
  if not bar or not m or m.track < 1 then
    return
  end
  bar_row = math.max(0, math.min(bar_row, m.track))
  local top = 1 + math.floor(bar_row * (m.total - m.height) / m.track + 0.5)
  if bar.list then
    pcall(function()
      bar.list:scroll(top, true, true)
    end)
  else
    -- A terminal window snaps back to keep the cursor visible, and the
    -- cursor sits on the last line while the terminal follows its output.
    -- Move the cursor into the new view -- the same thing manual scrolling
    -- does -- or the drag is undone on the next redraw. (Terminal-Insert is
    -- left before the drag loop starts: a stopinsert issued inside the
    -- getcharstr loop is deferred past it, and the view stays pinned to the
    -- terminal cursor for the whole drag.)
    pcall(vim.api.nvim_win_call, target_win, function()
      vim.fn.winrestview({
        topline = top,
        lnum = math.min(top + m.height - 1, m.total),
        col = 0,
      })
    end)
    refresh_terminal(target_win)
  end
end

-- Position from an absolute screen row, keeping the grab offset. The track
-- spans the target window's screen rows.
local function drag_to(target_win, screenrow, grab)
  if not vim.api.nvim_win_is_valid(target_win) then
    return
  end
  local win_row = vim.fn.win_screenpos(target_win)[1]
  scroll_to(target_win, screenrow - win_row - (grab or 0))
end

-- Which bar does this mouse position hit? Pure screen-rectangle math: the
-- float's own winid/wincol reporting differs between hitting the handle and
-- hitting the target window's last column, and both must act as the bar.
-- Returns the target window, the grab offset inside the handle, and whether
-- this was a track press (which centers the handle there first).
local function hit(mouse)
  if not mouse or not mouse.screenrow then
    return
  end
  for target_win, bar in pairs(bars) do
    if vim.api.nvim_win_is_valid(bar.win) and vim.api.nvim_win_is_valid(target_win) then
      local bar_position = vim.fn.win_screenpos(bar.win)
      local bar_col = bar_position[2]
      if mouse.screencol == bar_col then
        local bar_top = bar_position[1]
        local bar_height = vim.api.nvim_win_get_height(bar.win)
        if mouse.screenrow >= bar_top and mouse.screenrow < bar_top + bar_height then
          return target_win, mouse.screenrow - bar_top
        end
        local target_top = vim.fn.win_screenpos(target_win)[1]
        local target_height = vim.api.nvim_win_get_height(target_win)
        if mouse.screenrow >= target_top and mouse.screenrow < target_top + target_height then
          local m = metrics(target_win)
          if m then
            return target_win, math.floor(m.bar_height / 2), true
          end
        end
      end
    end
  end
end

-- Event-driven dragging: the press arms this state, and the drag/release
-- handlers below (plus the hooks in the global mouse hubs) steer it. A
-- blocking getchar loop is deliberately avoided -- a stopinsert issued
-- inside one is deferred past it, and from Terminal-Insert the view then
-- stays pinned to the terminal cursor for the whole drag.
local drag_state

-- Called from the global <LeftMouse> hubs. True when the press was on one of
-- our bars; drag and release events are then routed here too.
function M.handle_mouse(mouse)
  local target_win, grab, track_jump = hit(mouse)
  if not target_win then
    drag_state = nil
    return false
  end
  drag_state = { target = target_win, grab = grab }
  if vim.api.nvim_get_mode().mode:sub(1, 1) == "t" then
    -- Leave Terminal-Insert like a manual scroll would, or every redraw
    -- snaps the view back to the terminal's own cursor.
    vim.api.nvim_feedkeys(vim.keycode("<C-\\><C-n>"), "n", false)
  end
  if track_jump then
    vim.schedule(function()
      if drag_state and vim.api.nvim_win_is_valid(target_win) then
        drag_to(target_win, mouse.screenrow, grab)
      end
    end)
  end
  return true
end

-- True when a drag gesture on a bar is in progress and was consumed.
function M.handle_drag(mouse)
  if not drag_state then
    return false
  end
  local state = drag_state
  if not vim.api.nvim_win_is_valid(state.target) then
    drag_state = nil
    return false
  end
  local screenrow = mouse and mouse.screenrow
  vim.schedule(function()
    if drag_state == state and screenrow then
      drag_to(state.target, screenrow, state.grab)
    end
  end)
  return true
end

function M.handle_release()
  if not drag_state then
    return false
  end
  drag_state = nil
  return true
end

function M.setup()
  if patched then
    return
  end
  local ok, List = pcall(require, "snacks.picker.core.list")
  if not ok or type(List) ~= "table" or type(List.render) ~= "function" then
    return
  end
  patched = true
  local original_render = List.render
  List.render = function(self, ...)
    local result = original_render(self, ...)
    pcall(refresh, self)
    return result
  end
  local group = vim.api.nvim_create_augroup("picker_scrollbar_cleanup", { clear = true })
  -- The bar float is not torn down with the list window automatically, and
  -- no render runs for a list that has just been closed; drop it directly.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(event)
      local closed = tonumber(event.match)
      if closed and bars[closed] then
        drop_bar(closed)
      end
    end,
  })
  -- Baseline drag/release routing for every mode. The Git panel installs
  -- its own global <LeftDrag>/<LeftRelease> mappings for n/x/i once a panel
  -- opens; those overwrite these and chain back into handle_drag and
  -- handle_release, so both orders behave the same.
  vim.keymap.set({ "n", "x", "i", "t" }, "<LeftDrag>", function()
    return M.handle_drag(vim.fn.getmousepos()) and "" or "<LeftDrag>"
  end, { expr = true, silent = true, desc = "Drag a panel scrollbar" })
  vim.keymap.set({ "n", "x", "i", "t" }, "<LeftRelease>", function()
    return M.handle_release() and "" or "<LeftRelease>"
  end, { expr = true, silent = true, desc = "Finish a panel scrollbar drag" })
  -- Terminal bars follow real window scrolling and new output.
  vim.api.nvim_create_autocmd({ "WinScrolled", "WinResized", "TermOpen", "TermLeave" }, {
    group = group,
    callback = queue_terminal_refresh,
  })
  vim.api.nvim_create_autocmd("TermOpen", {
    group = group,
    callback = function(event)
      vim.api.nvim_buf_attach(event.buf, false, {
        on_lines = function()
          queue_terminal_refresh()
        end,
      })
    end,
  })
end

M._bars = bars
M._refresh = refresh
M._refresh_terminals = refresh_terminals
M._scroll_to = scroll_to
M._drag_to = drag_to
M._hit = hit
M._patched = function()
  return patched
end

return M
