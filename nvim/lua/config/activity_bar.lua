local PanelLayout = require("config.panel_layout")
local TerminalTabs = require("config.terminal_tabs")

local M = {}

local ACTIVITY_WIDTH = 3
local DEFAULT_SIDEBAR_WIDTH = 40
local MIN_SIDEBAR_WIDTH = 28
local MIN_EDITOR_WIDTH = 30
local RESIZE_DELAY = 80

local views = {
  { name = "explorer", icon = "󰙅", title = "Explorer" },
  { name = "search", icon = "", title = "Search" },
  { name = "git", icon = "", title = "Git" },
}

local view_index = {}
for index, view in ipairs(views) do
  view_index[view.name] = index
end

-- Neovim's tabline spans the whole screen, so Bufferline draws buffer tabs
-- above the Activity Bar and the sidebar unless space is reserved on the left.
-- Bufferline can reserve it, but `is_offset_section` only inspects the first
-- and last window of the layout row -- and the sidebar sits between the
-- Activity Bar and the editor, so it is never seen. Reserve the whole left
-- column through the Activity Bar's own offset entry, whose padding Activity
-- Bar keeps in sync with where the editor actually starts.
local BUFFERLINE_OFFSET_FILETYPE = "activity_bar"

local states = {}
local ns = vim.api.nvim_create_namespace("project_activity_bar")
local setup_done = false
local resize_generation = 0
local reflowing = false

local function valid_win(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function valid_tab(tab)
  return tab and vim.api.nvim_tabpage_is_valid(tab)
end

local function tab_for_win(win)
  return valid_win(win) and vim.api.nvim_win_get_tabpage(win) or nil
end

-- The Activity Bar column is chrome. Editing a file into it (`:edit`, a
-- Bufferline click that lands on the wrong window) leaves a 3-column split
-- showing a buffer, and every later render silently no-ops on the wiped
-- Activity Bar buffer. Other panels swap buffers on purpose, so only this
-- window is pinned.
local function pin_buffer(win)
  if vim.fn.exists("&winfixbuf") == 1 then
    pcall(function()
      vim.wo[win].winfixbuf = true
    end)
  end
end

-- Text-selection gestures do not belong in a panel: dragging starts a Visual
-- selection over a file tree or an icon strip and strands the panel in Visual
-- mode, and multi-clicks select a word or a line. Neutralise all of them per
-- panel buffer. Buffer-local is safe here because each of these gestures
-- follows a press that already focused the window, so the panel's buffer is
-- current by the time they arrive.
local SELECTION_GESTURES = {
  "<LeftDrag>",
  "<LeftRelease>",
  "<2-LeftMouse>",
  "<3-LeftMouse>",
  "<4-LeftMouse>",
  "<2-LeftDrag>",
  "<3-LeftDrag>",
  "<4-LeftDrag>",
  "<2-LeftRelease>",
  "<3-LeftRelease>",
  "<4-LeftRelease>",
}

local function disable_selection_gestures(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  for _, key in ipairs(SELECTION_GESTURES) do
    vim.keymap.set({ "n", "i", "x" }, key, "<Nop>", {
      buffer = buf,
      silent = true,
      desc = "No text selection inside project panels",
    })
  end
end

local function normalize_view(view)
  view = type(view) == "string" and view:lower() or view
  return view_index[view] and view or nil
end

local function project_root()
  if rawget(_G, "LazyVim") and LazyVim.root then
    return vim.fs.normalize(LazyVim.root())
  end
  return vim.fs.normalize(vim.fn.getcwd(0))
end

local function content_root(content)
  if not content then
    return
  end
  if content.picker then
    local root = content.picker.layout and content.picker.layout.root
    return root and root:valid() and root.win or nil
  end
  return valid_win(content.win) and content.win or nil
end

local function picker_windows(picker)
  local result = {}
  if not picker then
    return result
  end
  for _, item in pairs({
    picker.layout and picker.layout.root,
    picker.input and picker.input.win,
    picker.list and picker.list.win,
    picker.preview and picker.preview.win,
  }) do
    if item and item.win and valid_win(item.win) then
      result[item.win] = true
    end
  end
  return result
end

local function editor_candidate(state)
  if valid_win(state.editor_win) and tab_for_win(state.editor_win) == state.tab then
    return state.editor_win
  end
  local excluded = { [state.activity.win] = true }
  if state.slot_hold then
    excluded[state.slot_hold.win] = true
  end
  local root = content_root(state.content)
  if root then
    excluded[root] = true
  end
  for win in pairs(picker_windows(state.content and state.content.picker)) do
    excluded[win] = true
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(state.tab)) do
    if
      not excluded[win]
      and vim.api.nvim_win_get_config(win).relative == ""
      and vim.bo[vim.api.nvim_win_get_buf(win)].buftype ~= "terminal"
    then
      state.editor_win = win
      return win
    end
  end
end

-- Snacks flushes the UI (`nvim__redraw` with flush) after every window it
-- creates. Mid-mount that pushes half-built frames to the terminal -- the new
-- sidebar briefly painted at the far left before it is moved into the slot.
-- Suppress the flush (damage tracking stays) while a sidebar is being built;
-- the natural end-of-tick redraw then shows only the finished layout.
local flush_guard
local function guard_flush()
  if flush_guard or not vim.api.nvim__redraw then
    return
  end
  local original = vim.api.nvim__redraw
  flush_guard = original
  vim.api.nvim__redraw = function(opts, ...)
    if type(opts) == "table" and opts.flush then
      opts = vim.tbl_extend("force", opts, { flush = false })
    end
    return original(opts, ...)
  end
end

local function unguard_flush()
  if flush_guard then
    vim.api.nvim__redraw = flush_guard
    flush_guard = nil
  end
end

-- Switching views tears the old sidebar down asynchronously and mounts the
-- new one several ticks later. In that gap the editor and the terminal expand
-- into the vacated columns and are squeezed back afterwards -- measured as
-- 3-4 width changes per switch, and every one of them delivers SIGWINCH to
-- the terminal job, which then rewraps and garbles its output. Bridge the gap
-- with a one-column placeholder inside the old sidebar and freeze every other
-- window's width, so the vacated space can only flow placeholder <-> sidebar
-- and the rest of the layout never moves.
local function hold_slot(state, old_root)
  if state.slot_hold or not valid_win(old_root) then
    return
  end
  local frozen = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(state.tab)) do
    if vim.api.nvim_win_get_config(win).relative == "" and win ~= old_root then
      frozen[win] = vim.wo[win].winfixwidth
      vim.wo[win].winfixwidth = true
    end
  end
  -- 'equalalways' re-balances every window on each split and close, which is
  -- exactly the churn being prevented; keep it off for the whole handover.
  local equalalways = vim.o.equalalways
  vim.o.equalalways = false
  -- The placeholder's columns must come out of the sidebar itself, not the
  -- frozen remainder of the layout.
  vim.wo[old_root].winfixwidth = false
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local ok, placeholder = pcall(vim.api.nvim_open_win, buf, false, {
    win = old_root,
    split = "left",
    width = 1,
    style = "minimal",
  })
  if not ok or not valid_win(placeholder) then
    vim.o.equalalways = equalalways
    for win, fixed in pairs(frozen) do
      if valid_win(win) then
        vim.wo[win].winfixwidth = fixed
      end
    end
    return
  end
  -- The only window whose width is not fixed: closing the old sidebar hands
  -- its space to the placeholder, and the new sidebar takes it back from it.
  vim.wo[placeholder].winfixwidth = false
  state.slot_hold = { win = placeholder, frozen = frozen, equalalways = equalalways }
end

-- Closing the placeholder and lifting the width protection are separate
-- steps: the layout restore that follows the close runs a series of
-- win_splitmove calls, and with 'equalalways' back on each one re-balances
-- the whole layout -- measured squeezing the terminal to 5 columns
-- mid-restore. When such a state survives into the next tick (rapid
-- switching), the pty really is resized that small, the shell redraws its
-- prompt at 5 columns, and the terminal's content is destroyed for good.
-- The freeze therefore has to outlive the entire mount.
local function drop_slot_placeholder(state, absorber)
  local hold = state.slot_hold
  if not hold or not valid_win(hold.win) then
    return
  end
  local absorber_fixed
  if valid_win(absorber) and absorber ~= hold.win then
    absorber_fixed = vim.wo[absorber].winfixwidth
    vim.wo[absorber].winfixwidth = false
  end
  pcall(vim.api.nvim_win_close, hold.win, true)
  if absorber_fixed ~= nil and valid_win(absorber) then
    vim.wo[absorber].winfixwidth = absorber_fixed
  end
end

local function thaw_slot(state)
  local hold = state.slot_hold
  if not hold then
    return
  end
  state.slot_hold = nil
  for win, fixed in pairs(hold.frozen) do
    if valid_win(win) then
      vim.wo[win].winfixwidth = fixed
    end
  end
  if hold.equalalways ~= nil then
    vim.o.equalalways = hold.equalalways
  end
end

local function release_slot(state, absorber)
  drop_slot_placeholder(state, absorber)
  thaw_slot(state)
end

local function call_in_tab(tab, callback, anchor)
  if tab == vim.api.nvim_get_current_tabpage() then
    return callback()
  end
  anchor = valid_win(anchor) and tab_for_win(anchor) == tab and anchor or vim.api.nvim_tabpage_list_wins(tab)[1]
  if anchor then
    return vim.api.nvim_win_call(anchor, callback)
  end
end

local function available_width(state)
  local maximum = vim.o.columns - ACTIVITY_WIDTH - MIN_EDITOR_WIDTH - 2
  if maximum < MIN_SIDEBAR_WIDTH then
    return nil
  end
  return math.max(MIN_SIDEBAR_WIDTH, math.min(state.sidebar_width or DEFAULT_SIDEBAR_WIDTH, maximum))
end

local function render_activity(state)
  if not valid_win(state.activity.win) or not vim.api.nvim_buf_is_valid(state.activity.buf) then
    return
  end
  local lines = {}
  for _, view in ipairs(views) do
    lines[#lines + 1] = " " .. view.icon
  end
  vim.bo[state.activity.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.activity.buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(state.activity.buf, ns, 0, -1)
  local active = view_index[state.view]
  if active then
    vim.api.nvim_buf_set_extmark(state.activity.buf, ns, active - 1, 0, {
      line_hl_group = (state.collapsed or state.responsive_hidden) and "Comment" or "Visual",
      hl_eol = true,
    })
    -- 'cursorline' is drawn in unfocused windows too, and rewriting the whole
    -- buffer resets the stored cursor. Without this the cursorline and the
    -- active-view highlight drift onto different rows. Skip it while the user
    -- is moving through the bar with j/k, so navigation is not snapped back.
    if vim.api.nvim_get_current_win() ~= state.activity.win then
      pcall(vim.api.nvim_win_set_cursor, state.activity.win, { active, 0 })
    end
  end
  vim.bo[state.activity.buf].modifiable = false
end

local function focus_editor(state)
  local win = editor_candidate(state)
  if valid_win(win) and tab_for_win(win) == vim.api.nvim_get_current_tabpage() then
    pcall(vim.api.nvim_set_current_win, win)
  end
end

-- Snacks' Picker input re-enters Insert mode from BufEnter, and defers that to
-- the next tick when the Picker is mounted while a terminal has focus. By then
-- the panel that ends up focused is often the Explorer list or the editor, so
-- the stray `startinsert!` lands in a window that does not take typed input.
-- Undo it once the transition has settled, but never in a prompt or terminal.
local function normalize_mode()
  local function drop_insert()
    if vim.api.nvim_get_mode().mode:sub(1, 1) ~= "i" then
      return
    end
    local buftype = vim.bo[vim.api.nvim_get_current_buf()].buftype
    if buftype == "prompt" or buftype == "terminal" then
      return
    end
    pcall(vim.cmd.stopinsert)
  end
  -- Run twice: the stray `startinsert!` can be queued either before or after
  -- this call, and a Picker teardown can queue one a few ticks later still.
  vim.schedule(drop_insert)
  vim.defer_fn(drop_insert, 60)
end

local function configure_activity_buffer(state)
  local buf, win = state.activity.buf, state.activity.win
  vim.api.nvim_buf_set_name(buf, ("activity-bar://%d"):format(state.tab))
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  -- `:vnew` creates a *listed* buffer, so without this the Activity Bar's own
  -- scratch buffer shows up as a buffer tab and is reachable with <S-h>/<S-l>.
  vim.bo[buf].buflisted = false
  vim.bo[buf].filetype = "activity_bar"
  vim.wo[win].cursorline = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].statuscolumn = ""
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].wrap = false
  vim.wo[win].winfixwidth = true
  vim.wo[win].winbar = ""
  -- LazyVim enables 'list' globally, which would draw the `listchars` space
  -- dot in front of every icon. Panels are chrome, not file content.
  vim.wo[win].list = false
  pin_buffer(win)

  local function activate()
    local row = vim.api.nvim_win_get_cursor(win)[1]
    local view = views[row]
    if view then
      M.toggle(view.name, { focus = true, tab = state.tab })
    end
  end
  vim.keymap.set("n", "<CR>", activate, { buffer = buf, silent = true, desc = "Activate sidebar view" })
  vim.keymap.set("n", "<Space>", activate, { buffer = buf, silent = true, desc = "Activate sidebar view" })
  vim.keymap.set("n", "j", function()
    local row = vim.api.nvim_win_get_cursor(win)[1]
    vim.api.nvim_win_set_cursor(win, { row % #views + 1, 0 })
  end, { buffer = buf, silent = true, desc = "Next Activity Bar item" })
  vim.keymap.set("n", "k", function()
    local row = vim.api.nvim_win_get_cursor(win)[1]
    vim.api.nvim_win_set_cursor(win, { (row - 2) % #views + 1, 0 })
  end, { buffer = buf, silent = true, desc = "Previous Activity Bar item" })
  vim.keymap.set("n", "<Down>", "j", { buffer = buf, remap = true, silent = true })
  vim.keymap.set("n", "<Up>", "k", { buffer = buf, remap = true, silent = true })
  vim.keymap.set("n", "q", "<Nop>", { buffer = buf, silent = true, desc = "Disabled in project panels" })
  vim.keymap.set("n", "<Esc>", "<Nop>", { buffer = buf, silent = true, desc = "Disabled in project panels" })
  disable_selection_gestures(buf)
  render_activity(state)
end

local function create_activity(tab)
  local anchor = vim.api.nvim_get_current_win()
  local created = call_in_tab(tab, function()
    local editor = vim.api.nvim_get_current_win()
    local root = project_root()
    vim.cmd("topleft 3vnew")
    return {
      editor = editor,
      root = root,
      win = vim.api.nvim_get_current_win(),
      buf = vim.api.nvim_get_current_buf(),
    }
  end, anchor)
  if not created then
    return
  end
  local win, buf = created.win, created.buf
  local state = {
    tab = tab,
    root = created.root,
    view = "explorer",
    collapsed = true,
    responsive_hidden = false,
    sidebar_width = DEFAULT_SIDEBAR_WIDTH,
    generation = 0,
    editor_win = created.editor ~= win and created.editor or nil,
    activity = { win = win, buf = buf },
    search = { query = "", hidden = false, cursor = 1, top = 1 },
    explorer = { cursor = 1, top = 1 },
  }
  states[tab] = state
  configure_activity_buffer(state)
  pcall(vim.api.nvim_win_set_width, win, ACTIVITY_WIDTH)
  if tab == vim.api.nvim_get_current_tabpage() and valid_win(created.editor) then
    pcall(vim.api.nvim_set_current_win, created.editor)
  end
  return state
end

local function state_for(tab, create)
  tab = tab or vim.api.nvim_get_current_tabpage()
  local state = states[tab]
  if state and (not valid_tab(tab) or not valid_win(state.activity.win)) then
    states[tab] = nil
    state = nil
  end
  if not state and create and valid_tab(tab) then
    state = create_activity(tab)
  end
  return state
end

local function disable_picker_quit(picker)
  if not picker then
    return
  end
  for _, window in pairs({ picker.input and picker.input.win, picker.list and picker.list.win }) do
    local buf = window and window.buf
    if buf and vim.api.nvim_buf_is_valid(buf) then
      for _, key in ipairs({ "q", "<Esc>" }) do
        vim.keymap.set("n", key, "<Nop>", {
          buffer = buf,
          silent = true,
          desc = "Disabled in project panels",
        })
      end
      -- Snacks maps <Esc> to "cancel", which would close the panel. Disabling
      -- it outright instead trapped Insert mode in the Search prompt, so send
      -- it to Normal mode and leave the panel open.
      vim.keymap.set("i", "<Esc>", "<C-\\><C-n>", {
        buffer = buf,
        silent = true,
        desc = "Leave Insert mode without closing the panel",
      })
    end
  end
end

local function picker_tasks_done(picker)
  local finder_task = picker.finder and picker.finder.task
  local matcher_task = picker.matcher and picker.matcher.task
  return (not finder_task or finder_task._co == nil) and (not matcher_task or matcher_task._co == nil)
end

-- Snacks clears its matcher on the next scheduled tick in Picker:close(). An
-- aborted finder can still have a queued `done` callback at that point, which
-- then tries to resume the cleared matcher. Keep close idempotent, abort both
-- workers, and call the original close only after their completion callbacks.
-- This also covers a tab being closed by Neovim before Activity Bar receives
-- TabClosed.
local function stabilize_picker_close(picker)
  if not picker or picker._activity_close then
    return
  end
  local original_close = picker.close
  picker._activity_close = original_close
  picker.close = function(self)
    if self.closed or self._activity_closing then
      return
    end
    self._activity_closing = true
    self.finder:abort()
    self.matcher:abort()
    local function finish(attempt)
      if self.closed then
        return
      end
      if picker_tasks_done(self) or attempt >= 100 then
        self._activity_closing = false
        original_close(self)
        return
      end
      vim.defer_fn(function()
        finish(attempt + 1)
      end, 10)
    end
    finish(0)
  end
end

local function disable_search_ignored(picker)
  for _, window in pairs({ picker.input and picker.input.win, picker.list and picker.list.win }) do
    local buf = window and window.buf
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.keymap.set({ "n", "i" }, "<M-i>", "<Nop>", {
        buffer = buf,
        silent = true,
        desc = ".gitignore is always respected in project Search",
      })
    end
  end
end

local function refine_picker_mouse(picker)
  if not picker then
    return
  end
  for _, window in pairs({ picker.input and picker.input.win, picker.list and picker.list.win }) do
    disable_selection_gestures(window and window.buf)
  end
end

local function keep_search_preview(state, picker)
  for _, window in pairs({ picker.input and picker.input.win, picker.list and picker.list.win }) do
    local buf = window and window.buf
    if buf and vim.api.nvim_buf_is_valid(buf) and not vim.b[buf].activity_search_preview then
      vim.b[buf].activity_search_preview = true
      vim.api.nvim_create_autocmd("WinEnter", {
        buffer = buf,
        callback = function()
          if
            state.content
            and state.content.picker == picker
            and not picker.closed
            and picker.preview.main
            and not picker.preview.win:valid()
          then
            vim.schedule(function()
              if
                state.content
                and state.content.picker == picker
                and not picker.closed
                and not picker.preview.win:valid()
              then
                picker:toggle("preview", { enable = true })
              end
            end)
          end
        end,
      })
    end
  end
end

local function save_picker_position(target, picker, remember_file)
  if not picker or picker.closed then
    return
  end
  target.cursor = picker.list and picker.list.cursor or target.cursor
  target.top = picker.list and picker.list.top or target.top
  if picker.input and picker.input.filter then
    target.query = picker.input.filter.search or target.query
    target.pattern = picker.input.filter.pattern or target.pattern
  end
  if remember_file then
    local item = picker:current({ resolve = false })
    target.file = item and item.file or target.file
  end
end

local function save_content(state)
  local content = state.content
  if not content then
    return
  end
  local root = content_root(content)
  if root then
    state.sidebar_width = math.max(vim.api.nvim_win_get_width(root), MIN_SIDEBAR_WIDTH)
  end
  if content.kind == "search" and content.picker then
    save_picker_position(state.search, content.picker, false)
    state.search.hidden = content.picker.opts.hidden == true
  elseif content.kind == "explorer" and content.picker then
    save_picker_position(state.explorer, content.picker, true)
  end
end

local function close_native(content)
  local win = content and content.win
  if valid_win(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
end

local function release_closing(state, content, attempt)
  attempt = attempt or 0
  if state.closing ~= content then
    return
  end
  local picker_busy = content.picker and not content.picker.closed
  if (picker_busy or valid_win(content_root(content))) and attempt < 120 then
    vim.defer_fn(function()
      release_closing(state, content, attempt + 1)
    end, 10)
    return
  end
  if state.closing == content then
    state.closing = nil
    if valid_tab(state.tab) and states[state.tab] == state then
      vim.schedule(function()
        if valid_tab(state.tab) and states[state.tab] == state then
          M.reflow(state.tab)
        end
      end)
    end
  end
end

local function destroy_content(state)
  local content = state.content
  if not content then
    return
  end
  state.closing = content
  state.content = nil
  if content.kind == "git" and content.git_state then
    require("config.git_panel").detach(content.git_state)
    close_native(content)
  elseif content.picker and not content.picker.closed then
    -- With a slot hold in place, take the old windows down synchronously
    -- before the Picker's own (deferred, multi-tick) teardown runs. This is
    -- what lets the whole swap -- close old, open new, arrange -- complete
    -- inside a single tick: no frame ever shows the bare placeholder, so the
    -- sidebar's border lines never visibly drop out and reappear.
    if state.slot_hold then
      local root = content_root(content)
      if valid_win(root) then
        pcall(vim.api.nvim_win_close, root, true)
      end
      for win in pairs(picker_windows(content.picker)) do
        if valid_win(win) then
          pcall(vim.api.nvim_win_close, win, true)
        end
      end
    end
    if not content.picker.closed then
      content.picker:close()
    end
  else
    close_native(content)
  end
  vim.defer_fn(function()
    release_closing(state, content)
  end, 10)
end

local function sidebar_layout(width, preview, input_height)
  return {
    preview = preview,
    layout = {
      backdrop = false,
      width = width,
      min_width = 1,
      height = 0,
      position = "left",
      border = "none",
      box = "vertical",
      {
        win = "input",
        height = input_height or 1,
        border = true,
        title = "{title} {live} {flags}",
        title_pos = "center",
      },
      { win = "list", border = "none" },
      { win = "preview", title = "{preview}", height = 0.4, border = "top" },
    },
  }
end

local function restore_list_position(state, picker, saved, generation, remember_file, attempt)
  attempt = attempt or 0
  if
    state.generation ~= generation
    or not picker
    or picker.closed
    or state.content == nil
    or state.content.picker ~= picker
  then
    return
  end
  if picker.list and picker.list:count() > 0 then
    local cursor = math.min(saved.cursor or 1, picker.list:count())
    if remember_file and saved.file then
      for index = 1, picker.list:count() do
        local item = picker.list:get(index)
        if item and item.file == saved.file then
          cursor = index
          break
        end
      end
    end
    picker.list:view(cursor, saved.top or 1, true)
    return
  end
  if attempt < 50 then
    vim.defer_fn(function()
      restore_list_position(state, picker, saved, generation, remember_file, attempt + 1)
    end, 30)
  end
end

local function search_winbar(state, enabled)
  local highlight = enabled and "SnacksPickerToggleHidden" or "Comment"
  local label = enabled and " 󰈈 Hidden: on " or " 󰈉 Hidden: off "
  return ("%%#%s#%%%d@v:lua.ActivityBarSearchHiddenClick@%s%%X%%*"):format(highlight, state.tab, label)
end

local function set_search_winbar(state, picker, attempt)
  attempt = attempt or 0
  if not picker or picker.closed then
    return
  end
  if not picker.input or not picker.input.win:valid() then
    if attempt < 30 then
      vim.defer_fn(function()
        set_search_winbar(state, picker, attempt + 1)
      end, 10)
    end
    return
  end
  local winbar = search_winbar(state, picker.opts.hidden == true)
  picker.opts.win.input.wo = picker.opts.win.input.wo or {}
  picker.opts.win.input.wo.winbar = winbar
  picker.input.win.opts.wo = picker.input.win.opts.wo or {}
  picker.input.win.opts.wo.winbar = winbar
  vim.wo[picker.input.win.win].winbar = winbar
end

local function create_plain_sidebar(state, width, filetype, lines)
  local editor = editor_candidate(state)
  if not editor then
    return
  end
  vim.api.nvim_set_current_win(editor)
  vim.cmd(("topleft %dvnew"):format(width))
  local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(buf, ("%s://%d"):format(filetype, state.tab))
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].buflisted = false
  vim.bo[buf].filetype = filetype
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].statuscolumn = ""
  vim.wo[win].wrap = true
  vim.wo[win].winfixwidth = true
  vim.wo[win].list = false
  disable_selection_gestures(buf)
  return { win = win, buf = buf }
end

local function open_explorer(state, width, generation)
  local editor = editor_candidate(state)
  if not editor then
    return
  end
  vim.api.nvim_set_current_win(editor)
  local picker = Snacks.explorer({
    cwd = state.root,
    auto_close = false,
    enter = false,
    focus = false,
    layout = sidebar_layout(width, false),
  })
  if not picker then
    return
  end
  stabilize_picker_close(picker)
  picker:show()
  disable_picker_quit(picker)
  refine_picker_mouse(picker)
  picker.main = editor
  restore_list_position(state, picker, state.explorer, generation, true)
  return { kind = "explorer", picker = picker }
end

local function open_search(state, width, generation)
  if vim.fn.executable("rg") ~= 1 then
    local plain = create_plain_sidebar(state, width, "activity_search_error", {
      "",
      "   Search",
      "",
      "  ripgrep (`rg`) was not found.",
      "  Install it to search this project.",
    })
    return plain and vim.tbl_extend("force", plain, { kind = "search" }) or nil
  end

  local editor = editor_candidate(state)
  if not editor then
    return
  end
  vim.api.nvim_set_current_win(editor)
  local picker = Snacks.picker.grep({
    cwd = state.root,
    search = state.search.query or "",
    hidden = state.search.hidden == true,
    ignored = false,
    auto_close = false,
    enter = false,
    -- A Bufferline tab is a listed buffer, not a Neovim tabpage. Keep the
    -- shared editor window, reuse the existing buffer for the same path, and
    -- let Snacks add a different result buffer to the listed-buffer set.
    jump = { close = false, reuse_win = false },
    layout = sidebar_layout(width, "main", 2),
    title = "Search",
    win = {
      input = {
        wo = { winbar = search_winbar(state, state.search.hidden == true) },
      },
    },
  })
  if not picker then
    return
  end
  stabilize_picker_close(picker)
  picker:show()
  disable_picker_quit(picker)
  refine_picker_mouse(picker)
  disable_search_ignored(picker)
  picker.main = editor
  set_search_winbar(state, picker)
  restore_list_position(state, picker, state.search, generation, false)
  return { kind = "search", picker = picker }
end

local function open_git(state, width)
  local plain = create_plain_sidebar(state, width, "activity_git_slot", { "" })
  if not plain then
    return
  end
  local git_state = require("config.git_panel").open_in_window(plain.win, state.root, editor_candidate(state))
  if git_state then
    return { kind = "git", win = plain.win, git_state = git_state }
  end
  vim.bo[plain.buf].modifiable = true
  vim.api.nvim_buf_set_lines(plain.buf, 0, -1, false, {
    "",
    "   Git",
    "",
    "  This project is not a Git repository.",
  })
  vim.bo[plain.buf].modifiable = false
  vim.bo[plain.buf].filetype = "project_git_panel"
  return { kind = "git", win = plain.win, buf = plain.buf }
end

local openers = {
  explorer = open_explorer,
  search = open_search,
  git = open_git,
}

local function arrange_activity(state, root)
  if not valid_win(root) or not valid_win(state.activity.win) then
    return
  end
  local root_fixed = vim.wo[root].winfixwidth
  local activity_fixed = vim.wo[state.activity.win].winfixwidth
  vim.wo[root].winfixwidth = false
  vim.wo[state.activity.win].winfixwidth = false
  -- Snacks layouts with position="left" may move their root back to the
  -- outermost split during layout:update(), especially after a responsive
  -- hide/restore. Move it behind Activity Bar after every such update.
  local activity_position = vim.api.nvim_win_get_position(state.activity.win)
  local root_position = vim.api.nvim_win_get_position(root)
  local expected_root_col = activity_position[2] + vim.api.nvim_win_get_width(state.activity.win) + 1
  local aligned = root_position[1] == activity_position[1]
    and root_position[2] == expected_root_col
    and vim.api.nvim_win_get_height(root) == vim.api.nvim_win_get_height(state.activity.win)
  local ok, result = true, 0
  if not aligned then
    ok, result = pcall(vim.fn.win_splitmove, root, state.activity.win, {
      vertical = true,
      rightbelow = true,
    })
  end
  if valid_win(root) then
    vim.wo[root].winfixwidth = root_fixed
  end
  if ok and result == 0 and valid_win(state.activity.win) then
    pcall(vim.api.nvim_win_set_width, state.activity.win, ACTIVITY_WIDTH)
  end
  if valid_win(state.activity.win) then
    vim.wo[state.activity.win].winfixwidth = activity_fixed or true
  end
end

local function restore_placement(state, root, width)
  local placement = state.placement
  state.placement = nil
  local restored = false
  if state.slot_hold then
    -- A slot hold means the rest of the layout never moved: the placeholder
    -- kept the sidebar's columns and every other width was frozen, so the
    -- full snapshot rebuild has nothing to restore. Skipping it also skips
    -- its win_splitmove storm and the winrestcmd pass, which addresses
    -- windows by number and so resizes the wrong ones once the sidebar's
    -- window ids have changed. (Measured: the rebuild squeezes the terminal
    -- window through arbitrary widths intra-tick; that alone does not corrupt
    -- the terminal -- its screen only resizes with a redraw -- but there is
    -- no reason to leave the churn in.) Moving the new root behind the
    -- Activity Bar and folding the placeholder into it is all that is needed.
    arrange_activity(state, root)
    drop_slot_placeholder(state, root)
  elseif placement and placement.snapshot then
    restored = PanelLayout.restore(placement.snapshot, { [placement.win] = root }) == true
  end
  drop_slot_placeholder(state, root)
  -- Reassert both fixed widths after the restore. Neovim can transfer the
  -- removed sidebar's width to Activity Bar while the Picker closes.
  arrange_activity(state, root)
  local fixed = vim.wo[root].winfixwidth
  vim.wo[root].winfixwidth = false
  pcall(vim.api.nvim_win_set_width, root, width)
  vim.wo[root].winfixwidth = fixed or true
  state.sidebar_applied = width
  if valid_win(state.activity.win) then
    vim.wo[state.activity.win].winfixwidth = false
    pcall(vim.api.nvim_win_set_width, state.activity.win, ACTIVITY_WIDTH)
    vim.wo[state.activity.win].winfixwidth = true
  end
  return restored
end

local function focus_content(content)
  local win
  if content and content.picker then
    win = content.kind == "explorer" and content.picker.list and content.picker.list.win and content.picker.list.win.win
      or content.picker.input and content.picker.input.win and content.picker.input.win.win
  else
    win = content and content.win
  end
  if valid_win(win) then
    vim.api.nvim_set_current_win(win)
  end
end

local function finish_open(state, generation, width, focus)
  if state.generation ~= generation or not valid_tab(state.tab) or state.collapsed or state.responsive_hidden then
    return
  end
  guard_flush()
  local opener = openers[state.view]
  local ok, content = pcall(opener, state, width, generation)
  if not ok then
    unguard_flush()
    release_slot(state, editor_candidate(state))
    vim.schedule(function()
      vim.notify("Activity Bar failed to open " .. state.view .. ": " .. tostring(content), vim.log.levels.ERROR)
    end)
    return
  end
  if state.generation ~= generation then
    unguard_flush()
    if content then
      state.content = content
      destroy_content(state)
    end
    return
  end
  state.content = content
  local function mount(attempt)
    if state.generation ~= generation or state.content ~= content then
      unguard_flush()
      return
    end
    if not valid_tab(state.tab) then
      unguard_flush()
      release_slot(state)
      destroy_content(state)
      return
    end
    local root = content_root(content)
    if not root then
      if attempt < 50 then
        vim.defer_fn(function()
          mount(attempt + 1)
        end, 10)
      else
        unguard_flush()
        release_slot(state, editor_candidate(state))
      end
      return
    end
    if tab_for_win(root) ~= state.tab then
      unguard_flush()
      release_slot(state, editor_candidate(state))
      destroy_content(state)
      return
    end
    restore_placement(state, root, width)
    if content.picker then
      disable_picker_quit(content.picker)
      refine_picker_mouse(content.picker)
    end
    if content.kind == "search" and content.picker then
      disable_search_ignored(content.picker)
      keep_search_preview(state, content.picker)
      set_search_winbar(state, content.picker)
    end
    render_activity(state)
    if focus then
      focus_content(content)
    else
      focus_editor(state)
    end
    normalize_mode()
    M.reflow(state.tab)
    thaw_slot(state)
    unguard_flush()
  end
  mount(0)
end

local function begin_open(state, focus)
  if not valid_tab(state.tab) then
    return
  end
  if state.closing then
    local closing = state.closing
    local closing_picker = closing.picker
    local closing_win = content_root(closing)
    -- Only the old windows must be gone before the slot can be refilled; the
    -- Picker object's deferred data teardown is independent of the new
    -- content and waiting for it would push the reopen into a later tick,
    -- leaving a visible blank-sidebar frame.
    local busy = valid_win(closing_win)
    if not state.slot_hold then
      busy = busy or (closing_picker and not closing_picker.closed)
    end
    if busy then
      local generation = state.generation
      vim.defer_fn(function()
        if state.generation == generation then
          begin_open(state, focus)
        end
      end, 10)
      return
    end
    state.closing = nil
  end
  local width = available_width(state)
  if not width then
    release_slot(state, editor_candidate(state))
    state.responsive_hidden = true
    render_activity(state)
    focus_editor(state)
    return
  end
  state.responsive_hidden = false
  local generation = state.generation
  call_in_tab(state.tab, function()
    finish_open(state, generation, width, focus)
  end, editor_candidate(state))
end

local function replace_view(state, view, focus)
  state.generation = state.generation + 1
  local old_root = content_root(state.content)
  -- A switch that lands while the previous one is still in flight (its
  -- placeholder is holding the slot, state.content already gone) must inherit
  -- that hold, not tear it down: releasing here would run the rest of this
  -- transition unprotected, and its transient states -- which rapid clicking
  -- lets survive across ticks -- resize the terminal's pty and destroy its
  -- content. The bumped generation cancels the older transition's callbacks,
  -- and this transition's mount releases the inherited hold.
  if state.content then
    save_content(state)
    if old_root then
      state.placement = { snapshot = PanelLayout.capture(old_root), win = old_root }
      hold_slot(state, old_root)
    end
    destroy_content(state)
  end
  state.view = view
  state.collapsed = false
  state.responsive_hidden = false
  render_activity(state)
  begin_open(state, focus)
end

function M.open(view, opts)
  opts = opts or {}
  view = normalize_view(view) or "explorer"
  local state = state_for(opts.tab, true)
  if not state then
    return
  end
  local root = content_root(state.content)
  if state.view == view and root and not state.collapsed and not state.responsive_hidden then
    if opts.focus ~= false then
      focus_content(state.content)
    end
    return state
  end
  replace_view(state, view, opts.focus ~= false)
  return state
end

function M.close(opts)
  opts = opts or {}
  local state = state_for(opts.tab, false)
  if not state or state.collapsed then
    return false
  end
  release_slot(state, editor_candidate(state))
  state.generation = state.generation + 1
  local root = content_root(state.content)
  if state.content then
    save_content(state)
    if root then
      state.placement = { snapshot = PanelLayout.capture(root), win = root }
    end
    destroy_content(state)
  end
  state.collapsed = true
  state.responsive_hidden = false
  render_activity(state)
  focus_editor(state)
  normalize_mode()
  local scrollview = package.loaded["scrollview"]
  if scrollview and scrollview.refresh_impl_async then
    pcall(scrollview.refresh_impl_async)
  end
  return true
end

function M.toggle(view, opts)
  opts = opts or {}
  view = normalize_view(view) or "explorer"
  local state = state_for(opts.tab, true)
  if not state then
    return
  end
  if state.view == view and not state.collapsed and not state.responsive_hidden and content_root(state.content) then
    M.close({ tab = state.tab })
    return state
  end
  return M.open(view, opts)
end

function M.editor_window(tab)
  local state = state_for(tab, false)
  return state and editor_candidate(state) or nil
end

function M.owns_window(win, tab)
  local state = state_for(tab or tab_for_win(win), false)
  if not state or not valid_win(win) then
    return false
  end
  if win == state.activity.win or win == content_root(state.content) then
    return true
  end
  return picker_windows(state.content and state.content.picker)[win] == true
end

function M.current(tab)
  return state_for(tab, false)
end

function M.toggle_search_hidden(tab)
  local state = state_for(tab, false)
  local picker = state and state.content and state.content.kind == "search" and state.content.picker or nil
  if not picker or picker.closed then
    return
  end
  picker:action("toggle_hidden")
  state.search.hidden = picker.opts.hidden == true
  set_search_winbar(state, picker)
end

-- Snacks binds only <2-LeftMouse> on a picker list, so a folder in the
-- Explorer needs a double click to expand. Its `confirm` action already does
-- the right thing for a single click -- toggle a directory, open a file.
-- This has to live in the global mouse chain rather than a buffer-local
-- mapping: buffer-local mappings apply to the *current* buffer, so the first
-- click on an unfocused sidebar would only move focus and be swallowed.
-- True when the mouse is over one of this project's panels. Used to reject
-- text-selection gestures globally: buffer-local mappings only apply once the
-- panel already has focus, so a gesture started from the editor would still
-- reach the default handler on its first use.
function M._over_panel(mouse)
  local win = mouse and tonumber(mouse.winid)
  if not win or win < 1 or not valid_win(win) then
    return false
  end
  local state = state_for(tab_for_win(win), false)
  if not state then
    return false
  end
  if win == state.activity.win or win == content_root(state.content) then
    return true
  end
  if picker_windows(state.content and state.content.picker)[win] then
    return true
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local filetype = vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype or ""
  return filetype == "project_git_panel" or filetype == "activity_git_slot" or filetype == "activity_search_error"
end

function M._handle_list_click(mouse)
  local state = state_for(tab_for_win(mouse and mouse.winid), false)
  local picker = state and state.content and state.content.picker or nil
  local list = picker and not picker.closed and picker.list or nil
  if not list or not list.win or not list.win:valid() or mouse.winid ~= list.win.win then
    return false
  end
  local row = mouse.line
  if not row or row < 1 or row > list:count() then
    return false
  end
  -- getmousepos() reports the last line for a click below the final entry.
  local position = vim.fn.screenpos(list.win.win, row, 1)
  if position.row == 0 or mouse.screenrow ~= position.row then
    return false
  end
  vim.schedule(function()
    if picker.closed or not list.win:valid() then
      return
    end
    vim.api.nvim_set_current_win(list.win.win)
    list:move(row, true, true)
    picker:action("confirm")
  end)
  return true
end

function M._handle_mouse(mouse)
  mouse = mouse or vim.fn.getmousepos()
  local state = state_for(tab_for_win(mouse and mouse.winid), false)
  if not state or mouse.winid ~= state.activity.win or (mouse.line or 0) < 1 or mouse.line > #views then
    return false
  end
  local position = vim.fn.screenpos(state.activity.win, mouse.line, 1)
  if position.row == 0 or mouse.screenrow ~= position.row then
    return false
  end
  local view = views[mouse.line].name
  vim.schedule(function()
    if not valid_win(state.activity.win) then
      return
    end
    local mode = vim.api.nvim_get_mode().mode
    if mode:sub(1, 1) == "i" or mode:sub(1, 1) == "t" then
      pcall(vim.cmd.stopinsert)
    elseif mode == "v" or mode == "V" or mode == "\22" then
      pcall(vim.cmd, "normal! \027")
    end
    vim.api.nvim_set_current_win(state.activity.win)
    vim.api.nvim_win_set_cursor(state.activity.win, { mouse.line, 0 })
    M.toggle(view, { focus = true, tab = state.tab })
  end)
  return true
end

local function terminal_in_tab(state)
  local root = TerminalTabs._normalize_root(state.root)
  local group = TerminalTabs._groups[root]
  local terminal = group and group.visible and group.active and group.active.terminal or nil
  return terminal and terminal:win_valid() and tab_for_win(terminal.win) == state.tab and terminal.win or nil
end

local function arrange_terminal(state)
  local terminal = terminal_in_tab(state)
  local editor = editor_candidate(state)
  if not valid_win(terminal) or not valid_win(editor) then
    return
  end
  local minimum = vim.o.lines >= 24 and 6 or 2
  local editor_minimum = vim.o.lines >= 24 and 8 or 3
  -- Measure before any split move: win_splitmove() re-creates the split and
  -- leaves the terminal at Neovim's minimum height, which must not be mistaken
  -- for a height the user chose.
  local before = vim.api.nvim_win_get_height(terminal)
  local terminal_pos = vim.api.nvim_win_get_position(terminal)
  local editor_pos = vim.api.nvim_win_get_position(editor)
  if terminal_pos[2] ~= editor_pos[2] or vim.api.nvim_win_get_width(terminal) ~= vim.api.nvim_win_get_width(editor) then
    local fixed = vim.wo[terminal].winfixheight
    vim.wo[terminal].winfixheight = false
    pcall(vim.fn.win_splitmove, terminal, editor, { vertical = false, rightbelow = true })
    if valid_win(terminal) then
      vim.wo[terminal].winfixheight = fixed or true
    end
  end
  if valid_win(terminal) and valid_win(editor) then
    local current = vim.api.nvim_win_get_height(terminal)
    local total = current + vim.api.nvim_win_get_height(editor)
    -- Impose the default split only the first time this tab's terminal is
    -- arranged. After that keep the height it already had, so resizing the
    -- terminal survives switching sidebar views; a height below the minimum
    -- came from a layout rebuild rather than the user, so restore the
    -- remembered one instead of locking the squashed value in.
    local remembered = state.terminal_height
    local desired
    if not remembered then
      desired = math.floor(total * 0.3)
    elseif before ~= remembered and before >= minimum then
      desired = before
    else
      desired = remembered
    end
    local target = math.max(minimum, math.min(desired, math.max(1, total - editor_minimum)))
    if target ~= current then
      vim.wo[terminal].winfixheight = false
      pcall(vim.api.nvim_win_set_height, terminal, target)
      if valid_win(terminal) then
        vim.wo[terminal].winfixheight = true
      end
    end
    state.terminal_height = target
  end
end

-- Match the reserved tabline width to the real distance between the left edge
-- and the central editor, so buffer tabs start exactly above the editor in
-- every state: sidebar open, collapsed, responsively hidden, or resized.
local function sync_tabline_offset()
  local config = package.loaded["bufferline.config"]
  local offsets = config and config.options and config.options.offsets
  if not offsets then
    return
  end
  local entry
  for _, offset in ipairs(offsets) do
    if offset.filetype == BUFFERLINE_OFFSET_FILETYPE then
      entry = offset
      break
    end
  end
  if not entry then
    return
  end
  local padding = 0
  local state = state_for(nil, false)
  if state and valid_win(state.activity.win) then
    local editor = editor_candidate(state)
    if valid_win(editor) and tab_for_win(editor) == state.tab then
      local activity = vim.api.nvim_win_get_position(state.activity.win)
      local editor_position = vim.api.nvim_win_get_position(editor)
      padding = editor_position[2] - activity[2] - vim.api.nvim_win_get_width(state.activity.win)
      padding = math.max(0, padding)
    end
  end
  if entry.padding ~= padding then
    entry.padding = padding
    pcall(vim.cmd, "redrawtabline")
  end
end

function M.reflow(tab)
  if reflowing then
    return
  end
  local state = state_for(tab, false)
  if not state then
    return
  end
  reflowing = true
  local ok, err = pcall(call_in_tab, state.tab, function()
    if valid_win(state.activity.win) then
      vim.wo[state.activity.win].winfixwidth = false
      pcall(vim.api.nvim_win_set_width, state.activity.win, ACTIVITY_WIDTH)
      vim.wo[state.activity.win].winfixwidth = true
    end
    local root = content_root(state.content)
    -- A width that no longer matches what Activity Bar last applied came from
    -- the user dragging the sidebar border. Adopt it, or the next reflow (a
    -- terminal resize, a view switch) would silently undo the drag.
    if root and state.sidebar_applied and not state.closing and not state.collapsed and not state.responsive_hidden then
      local current = vim.api.nvim_win_get_width(root)
      if current ~= state.sidebar_applied and current >= MIN_SIDEBAR_WIDTH then
        state.sidebar_width = current
      end
    end
    local width = available_width(state)
    if not width and root and not state.collapsed then
      release_slot(state, editor_candidate(state))
      save_content(state)
      state.generation = state.generation + 1
      state.placement = { snapshot = PanelLayout.capture(root), win = root }
      state.responsive_hidden = true
      destroy_content(state)
      focus_editor(state)
    elseif width and state.responsive_hidden and not state.collapsed then
      state.responsive_hidden = false
      state.generation = state.generation + 1
      begin_open(state, false)
    elseif width and root then
      local fixed = vim.wo[root].winfixwidth
      vim.wo[root].winfixwidth = false
      pcall(vim.api.nvim_win_set_width, root, width)
      vim.wo[root].winfixwidth = fixed or true
      if state.content and state.content.picker and state.content.picker.layout then
        state.content.picker.layout:update()
      end
      arrange_activity(state, root)
      if valid_win(root) then
        vim.wo[root].winfixwidth = false
        pcall(vim.api.nvim_win_set_width, root, width)
        vim.wo[root].winfixwidth = true
      end
      state.sidebar_applied = width
      if state.content and state.content.kind == "search" and state.content.picker then
        set_search_winbar(state, state.content.picker)
      end
    end
    arrange_terminal(state)
    render_activity(state)
  end, editor_candidate(state))
  reflowing = false
  if not ok then
    vim.schedule(function()
      vim.notify("Activity Bar layout reflow failed: " .. tostring(err), vim.log.levels.ERROR)
    end)
  end
  pcall(require("config.git_panel").reflow_layout)
  sync_tabline_offset()
  -- Scrollbars follow the sidebar swap in the next tick or two rather than
  -- trailing it by scrollview's own deferred autocmd schedule.
  local scrollview = package.loaded["scrollview"]
  if scrollview and scrollview.refresh_impl_async then
    pcall(scrollview.refresh_impl_async)
  end
end

function M.queue_reflow(delay, tab)
  resize_generation = resize_generation + 1
  local generation = resize_generation
  vim.defer_fn(function()
    if generation == resize_generation then
      M.reflow(tab)
    end
  end, delay or RESIZE_DELAY)
end

function M.open_all_panels()
  local state = M.open((state_for(nil, false) or {}).view or "explorer", { focus = false })
  TerminalTabs.open(state and state.root or project_root(), false)
  vim.defer_fn(function()
    if state then
      M.reflow(state.tab)
      focus_editor(state)
      normalize_mode()
    end
  end, 100)
end

function M.close_current_panel()
  local buf = vim.api.nvim_get_current_buf()
  local managed, root = TerminalTabs.owns_buffer(buf)
  if managed then
    TerminalTabs.hide(root)
    return
  end
  local win = vim.api.nvim_get_current_win()
  if M.owns_window(win) then
    M.close()
    return
  end
  local git = require("config.git_panel").current()
  if git and git.preview_layout and (win == git.preview_layout.main_win or win == git.preview_layout.after_win) then
    require("config.git_panel").close_current_panel()
    return
  end
  Snacks.notify.info("The current window is not a project panel")
end

-- Keep the native mouse event intact so Neovim can still place the terminal
-- cursor and dispatch winbar/statusline clicks. Enter terminal-input mode on
-- the following tick as an explicit fallback: depending on the source mode
-- and a concurrent panel reflow, the native click can otherwise focus the
-- terminal window while leaving it in Normal mode.
function M._queue_terminal_insert(mouse)
  local win = mouse and tonumber(mouse.winid) or nil
  if not win or win < 1 or not valid_win(win) then
    return false
  end
  local buf = vim.api.nvim_win_get_buf(win)
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "terminal" then
    return false
  end
  vim.schedule(function()
    if valid_win(win) and vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_win_get_buf(win) == buf then
      vim.api.nvim_set_current_win(win)
      vim.cmd.startinsert()
    end
  end)
  return true
end

function M.setup()
  if setup_done then
    return
  end
  setup_done = true

  vim.keymap.set({ "n", "x", "i", "t" }, "<LeftMouse>", function()
    local mouse = vim.fn.getmousepos()
    if M._handle_mouse(mouse) then
      return ""
    end
    local scrollbar = package.loaded["config.picker_scrollbar"]
    if scrollbar and scrollbar.handle_mouse and scrollbar.handle_mouse(mouse) then
      return ""
    end
    if M._handle_list_click(mouse) then
      return ""
    end
    M._queue_terminal_insert(mouse)
    return "<LeftMouse>"
  end, {
    expr = true,
    replace_keycodes = true,
    silent = true,
    desc = "Activate Activity Bar item",
  })

  -- Multi-click gestures select a word or a line. Inside a panel that is
  -- meaningless and strands it in Visual mode, so swallow them there. This
  -- has to be global for the same reason the single click is: the panel's
  -- buffer is not current until the press has been processed.
  for _, key in ipairs({
    "<2-LeftMouse>",
    "<3-LeftMouse>",
    "<4-LeftMouse>",
    "<2-LeftDrag>",
    "<3-LeftDrag>",
    "<4-LeftDrag>",
    "<2-LeftRelease>",
    "<3-LeftRelease>",
    "<4-LeftRelease>",
  }) do
    local lhs = key
    vim.keymap.set({ "n", "x", "i", "t" }, lhs, function()
      local mouse = vim.fn.getmousepos()
      if M._over_panel(mouse) then
        return ""
      end
      -- The project terminal is not an Activity Bar panel, but selecting its
      -- rendered output is just as meaningless and drops it out of Terminal
      -- mode.
      local scrollbar = package.loaded["config.picker_scrollbar"]
      if scrollbar and scrollbar._over_terminal and scrollbar._over_terminal(mouse) then
        return ""
      end
      return lhs
    end, { expr = true, silent = true, desc = "No text selection inside project panels" })
  end

  local group = vim.api.nvim_create_augroup("project_activity_bar", { clear = true })
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      M.queue_reflow()
    end,
  })
  vim.api.nvim_create_autocmd({ "WinResized", "WinClosed", "WinNew" }, {
    group = group,
    callback = function()
      -- Dragging a window border never reaches reflow(), so the reserved
      -- tabline width has to follow the layout on its own.
      vim.schedule(sync_tabline_offset)
    end,
  })
  vim.api.nvim_create_autocmd("TabNewEntered", {
    group = group,
    callback = function()
      local tab = vim.api.nvim_get_current_tabpage()
      vim.schedule(function()
        if #vim.api.nvim_list_uis() > 0 and valid_tab(tab) then
          M.open("explorer", { focus = false, tab = tab })
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd("TabEnter", {
    group = group,
    callback = function()
      local state = state_for(nil, false)
      if state then
        M.queue_reflow(20, state.tab)
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(event)
      local closed = tonumber(event.match)
      if not closed then
        return
      end
      for tab, state in pairs(states) do
        if state.activity.win == closed then
          -- `:only`, `:q`, or a plugin closed the Activity Bar column itself.
          -- Tear the sidebar down with it, or its Picker stays alive with no
          -- view able to reach it and leaks into the next open.
          states[tab] = nil
          state.generation = state.generation + 1
          vim.schedule(function()
            destroy_content(state)
          end)
          return
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("TabClosed", {
    group = group,
    callback = function()
      for tab in pairs(states) do
        if not valid_tab(tab) then
          local state = states[tab]
          state.generation = state.generation + 1
          if state.content then
            destroy_content(state)
          end
          states[tab] = nil
        end
      end
    end,
  })
end

_G.ActivityBarSearchHiddenClick = function(minwid, _, button)
  if button == "l" or button == "left" then
    vim.schedule(function()
      M.toggle_search_hidden(tonumber(minwid))
    end)
  end
end

M._sync_tabline_offset = sync_tabline_offset
M._states = states
M._available_width = available_width
M._content_root = content_root
M._views = views

return M
