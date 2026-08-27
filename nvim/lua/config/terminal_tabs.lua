local PanelLayout = require("config.panel_layout")

local M = {}

local WINBAR = "%!v:lua.require'config.terminal_tabs'.render()"
local TITLE_WIDTH = 24
local MAX_VISIBLE = 20

local groups = {}
local closed_placements = {}
local click_targets = {}
local root_resolver
local layout_callback
local layout_cancel_callback
local layout_request_generation = 0

-- Neovim's default TermClose handler deletes a successful no-argument shell
-- before buffer-local handlers run. Keep that default for ordinary terminals,
-- but let this controller replace an exited managed shell in its existing host
-- window first.
local function protect_managed_terminals()
  local description = "Automatically close terminal buffers when started with no arguments and exiting without an error"
  for _, autocmd in ipairs(vim.api.nvim_get_autocmds({ event = "TermClose" })) do
    if
      autocmd.group_name == "nvim.terminal"
      and autocmd.desc == description
      and type(autocmd.callback) == "function"
    then
      local original = autocmd.callback
      vim.api.nvim_del_autocmd(autocmd.id)
      vim.api.nvim_create_autocmd("TermClose", {
        group = autocmd.group,
        pattern = "*",
        nested = true,
        desc = description .. " (except managed project terminals)",
        callback = function(args)
          if vim.api.nvim_buf_is_valid(args.buf) and vim.b[args.buf].project_terminal_root then
            return
          end
          return original(args)
        end,
      })
      return
    end
  end
end

protect_managed_terminals()

local function normalize_root(root)
  root = vim.fs.normalize(root or vim.fn.getcwd(0))
  return (vim.uv or vim.loop).fs_realpath(root) or root
end

local function current_root(root)
  if root and root ~= "" then
    return normalize_root(root)
  end

  local buf = vim.api.nvim_get_current_buf()
  local managed_root = vim.b[buf].project_terminal_root
  if type(managed_root) == "string" and managed_root ~= "" then
    return normalize_root(managed_root)
  end
  if root_resolver then
    local ok, resolved = pcall(root_resolver)
    if ok and type(resolved) == "string" and resolved ~= "" then
      return normalize_root(resolved)
    end
  end
  if rawget(_G, "LazyVim") and LazyVim.root then
    return normalize_root(LazyVim.root())
  end
  return normalize_root(vim.fn.getcwd(0))
end

local function request_layout()
  layout_request_generation = layout_request_generation + 1
  local generation = layout_request_generation
  if layout_callback then
    vim.schedule(function()
      if generation == layout_request_generation then
        layout_callback()
      end
    end)
  end
end

local function cancel_layout_request()
  layout_request_generation = layout_request_generation + 1
  if layout_cancel_callback then
    layout_cancel_callback()
  end
end

local function redraw()
  vim.schedule(function()
    pcall(vim.cmd.redrawstatus)
  end)
end

local function sanitize_title(title)
  return tostring(title or ""):gsub("[%c]", " "):gsub("%s+", " "):match("^%s*(.-)%s*$")
end

local function truncate_display(text, width)
  text = sanitize_title(text)
  width = math.max(tonumber(width) or 0, 0)
  if width == 0 then
    return ""
  end
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  if width == 1 then
    return "…"
  end

  local budget = width - 1
  local prefix = {}
  local used = 0
  for index = 0, vim.fn.strchars(text) - 1 do
    local char = vim.fn.strcharpart(text, index, 1)
    local char_width = vim.fn.strdisplaywidth(char)
    if char_width > 0 and used + char_width > budget then
      break
    end
    prefix[#prefix + 1] = char
    used = used + char_width
  end
  return table.concat(prefix) .. "…"
end

local function status_escape(text)
  return tostring(text or ""):gsub("%%", "%%%%")
end

local function terminal_title(item)
  local title
  if item and item.buf and vim.api.nvim_buf_is_valid(item.buf) then
    title = vim.b[item.buf].term_title
  end
  title = sanitize_title(title)
  return title ~= "" and title or ("Terminal %d"):format(item and item.number or 0)
end

local function group_for(root, create)
  root = current_root(root)
  local group = groups[root]
  if not group and create then
    group = {
      root = root,
      items = {},
      next_number = 1,
      page_start = 1,
      visible = false,
      placement = closed_placements[root],
    }
    groups[root] = group
  end
  return group, root
end

local function item_index(group, wanted)
  if not group then
    return
  end
  for index, item in ipairs(group.items) do
    if item == wanted or item.terminal == wanted or item.number == wanted then
      return index, item
    end
  end
end

local function active_index(group)
  return item_index(group, group and group.active)
end

-- Select a bounded page of ordered tabs. When the user pages away from the
-- active terminal, pin that terminal at the corresponding edge so it never
-- disappears from the winbar.
local function layout(group, width)
  local count = #group.items
  width = math.max(tonumber(width) or 0, 1)
  if count == 0 then
    return { entries = {}, start = 1, page_size = 0, left = false, right = false }
  end

  local start = math.max(1, math.min(group.page_start or 1, count))
  local left = start > 1
  local function select_page(available)
    local selected = {}
    local used = 0
    for index = start, count do
      local item_width = math.min(vim.fn.strdisplaywidth(terminal_title(group.items[index])), TITLE_WIDTH) + 4
      if #selected > 0 and used + item_width > available then
        break
      end
      selected[#selected + 1] = index
      used = used + item_width
      if #selected == MAX_VISIBLE then
        break
      end
    end
    return selected, used
  end

  local available = math.max(width - 3 - (left and 3 or 0) - 3, 5)
  local indices, used = select_page(available)
  local right = indices[#indices] < count
  if not right then
    available = math.max(width - 3 - (left and 3 or 0), 5)
    indices, used = select_page(available)
  end
  local page_size = #indices

  local active = active_index(group) or 1
  if active < indices[1] then
    local active_width = math.min(vim.fn.strdisplaywidth(terminal_title(group.items[active])), TITLE_WIDTH) + 4
    while #indices > 1 and used + active_width > available do
      local removed = table.remove(indices)
      used = used - math.min(vim.fn.strdisplaywidth(terminal_title(group.items[removed])), TITLE_WIDTH) - 4
    end
    table.insert(indices, 1, active)
    used = used + active_width
  elseif active > indices[#indices] then
    local active_width = math.min(vim.fn.strdisplaywidth(terminal_title(group.items[active])), TITLE_WIDTH) + 4
    while #indices > 1 and used + active_width > available do
      local removed = table.remove(indices)
      used = used - math.min(vim.fn.strdisplaywidth(terminal_title(group.items[removed])), TITLE_WIDTH) - 4
    end
    indices[#indices + 1] = active
    used = used + active_width
  end

  local title_budget = math.max(available - 4 * #indices, #indices)
  local widths = {}
  for position = 1, #indices do
    widths[position] = 1
  end
  local remaining = math.max(title_budget - #indices, 0)
  while remaining > 0 do
    local changed = false
    for position, index in ipairs(indices) do
      local wanted = math.min(vim.fn.strdisplaywidth(terminal_title(group.items[index])), TITLE_WIDTH)
      if widths[position] < wanted and remaining > 0 then
        widths[position] = widths[position] + 1
        remaining = remaining - 1
        changed = true
      end
    end
    if not changed then
      break
    end
  end

  local entries = {}
  for position, index in ipairs(indices) do
    entries[#entries + 1] = {
      index = index,
      item = group.items[index],
      title = truncate_display(terminal_title(group.items[index]), widths[position]),
    }
  end
  return {
    entries = entries,
    start = start,
    page_size = page_size,
    left = left,
    right = right,
  }
end

local function recenter(group, index, width)
  local probe = layout(group, width or group.last_width or 80)
  group.page_start = math.max(1, index - probe.page_size + 1)
end

local function set_winbar(item)
  local terminal = item and item.terminal
  if not terminal then
    return
  end
  terminal.opts.wo = terminal.opts.wo or {}
  terminal.opts.wo.winbar = WINBAR
  if terminal:win_valid() then
    vim.wo[terminal.win].winbar = WINBAR
  end
end

local function hide_windows(group)
  for _, item in ipairs(group.items) do
    if item.terminal and item.terminal:win_valid() then
      item.terminal:hide()
    end
  end
end

local function host_in_tab(group, tab)
  for _, item in ipairs(group.items) do
    local terminal = item.terminal
    if terminal and terminal:win_valid() and vim.api.nvim_win_get_tabpage(terminal.win) == tab then
      return item, terminal.win
    end
  end
end

local function call_in_tab(tab, callback, anchor)
  if tab == vim.api.nvim_get_current_tabpage() then
    return callback()
  end
  if not anchor or not vim.api.nvim_win_is_valid(anchor) or vim.api.nvim_win_get_tabpage(anchor) ~= tab then
    anchor = vim.api.nvim_tabpage_list_wins(tab)[1]
  end
  assert(anchor and vim.api.nvim_win_is_valid(anchor), "project panel tab has no usable window")
  return vim.api.nvim_win_call(anchor, callback)
end

local function capture_placement(group)
  local item, win = host_in_tab(group, group.tab)
  if not item or not win then
    return
  end
  return {
    terminal_win = win,
    snapshot = PanelLayout.capture(win),
  }
end

local function restore_placement(group, item)
  local placement = group.placement
  local terminal = item and item.terminal
  if
    not placement
    or not placement.snapshot
    or not terminal
    or not terminal:win_valid()
    or not vim.api.nvim_tabpage_is_valid(placement.snapshot.tab)
    or vim.api.nvim_win_get_tabpage(terminal.win) ~= placement.snapshot.tab
  then
    return false
  end
  local ok = PanelLayout.restore(placement.snapshot, { [placement.terminal_win] = terminal.win })
  if ok then
    group.placement = nil
    closed_placements[group.root] = nil
    cancel_layout_request()
  end
  return ok
end

local function mark_bottom_terminal(terminal, win)
  terminal.opts.position = "bottom"
  terminal.opts.relative = "editor"
  terminal.opts.stack = true
  vim.w[win].snacks_win = {
    id = terminal.id,
    position = "bottom",
    relative = "editor",
    stack = true,
  }
  vim.wo[win].winfixheight = true
end

local function focus_terminal(item)
  local terminal = item and item.terminal
  if not terminal or not terminal:win_valid() then
    return
  end
  vim.api.nvim_set_current_win(terminal.win)
  vim.schedule(function()
    if terminal:win_valid() and vim.api.nvim_get_current_win() == terminal.win then
      vim.cmd.startinsert()
    end
  end)
end

-- Snacks normally switches split terminals by closing one split and opening
-- another. In a mixed Explorer/Git/editor layout that can attach the new split
-- to a different branch of the window tree. Rebind the Snacks objects around
-- the existing window instead, so only its buffer changes.
local function mount_in_host(group, item, host_item, host_win, focus, target_tab)
  if not vim.api.nvim_win_is_valid(host_win) then
    return
  end
  target_tab = target_tab or vim.api.nvim_win_get_tabpage(host_win)
  if item.terminal:win_valid() and item.terminal.win ~= host_win then
    item.terminal:hide()
  end
  if host_item and host_item ~= item and host_item.terminal.win == host_win then
    host_item.terminal.win = nil
  end

  local current_tab = vim.api.nvim_get_current_tabpage()
  local function mount()
    local previous_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(host_win)
    item.terminal.opts.position = "current"
    item.terminal.opts.enter = true
    item.terminal:show()
    mark_bottom_terminal(item.terminal, host_win)
    set_winbar(item)
    if focus and target_tab == current_tab then
      focus_terminal(item)
    elseif previous_win ~= host_win and vim.api.nvim_win_is_valid(previous_win) then
      pcall(vim.api.nvim_set_current_win, previous_win)
    end
  end

  if target_tab ~= current_tab then
    call_in_tab(target_tab, mount, host_win)
  else
    mount()
  end
  group.active = item
  group.visible = true
  group.tab = target_tab
  redraw()
  return item.terminal
end

local function show_item(group, item, focus, target_tab)
  if not item or item.removing or not item.terminal:buf_valid() then
    return
  end

  local current_tab = vim.api.nvim_get_current_tabpage()
  target_tab = target_tab and vim.api.nvim_tabpage_is_valid(target_tab) and target_tab or current_tab
  if
    group.active == item
    and group.visible
    and item.terminal:win_valid()
    and vim.api.nvim_win_get_tabpage(item.terminal.win) == target_tab
  then
    set_winbar(item)
    if focus and target_tab == current_tab then
      focus_terminal(item)
    end
    return item.terminal
  end

  local host_item, host_win = host_in_tab(group, target_tab)
  if host_item and host_item ~= item then
    return mount_in_host(group, item, host_item, host_win, focus, target_tab)
  end

  hide_windows(group)
  local previous_win = vim.api.nvim_get_current_win()
  local function show()
    item.terminal.opts.enter = focus == true
    item.terminal:show()
    set_winbar(item)
  end

  if target_tab ~= current_tab then
    call_in_tab(target_tab, show)
  else
    show()
  end

  group.active = item
  group.visible = true
  group.tab = target_tab
  local restored = restore_placement(group, item)
  if focus and target_tab == current_tab then
    focus_terminal(item)
  elseif target_tab == current_tab and vim.api.nvim_win_is_valid(previous_win) then
    pcall(vim.api.nvim_set_current_win, previous_win)
  end
  if not restored then
    group.placement = nil
    request_layout()
  end
  redraw()
  return item.terminal
end

local function remove_item(group, item, opts)
  opts = opts or {}
  local index = item_index(group, item)
  if not index or item.removing then
    return false
  end

  item.removing = true
  local was_active = group.active == item
  local was_visible = group.visible
  local display_tab = group.tab
  local final_placement
  if #group.items == 1 then
    final_placement = was_visible and capture_placement(group) or group.placement
  end
  local focus = opts.focus == true
    or (item.terminal:win_valid() and vim.api.nvim_get_current_win() == item.terminal.win)

  local host_win
  if was_active and was_visible and #group.items > 1 and item.terminal:win_valid() then
    host_win = item.terminal.win
    item.terminal.win = nil
  end

  table.remove(group.items, index)
  click_targets[item.buf] = nil
  local neighbor
  local mounted_neighbor = false
  if #group.items > 0 and was_active then
    neighbor = group.items[math.min(index, #group.items)]
    group.active = neighbor
    recenter(group, math.min(index, #group.items))
    if was_visible and host_win and vim.api.nvim_win_is_valid(host_win) then
      -- Move the host to the neighbor before deleting the old terminal
      -- buffer. :bdelete closes windows that still display that buffer.
      mount_in_host(group, neighbor, nil, host_win, focus, display_tab)
      mounted_neighbor = true
    end
  end

  if opts.terminate ~= false and item.terminal:buf_valid() then
    item.terminal:close()
  elseif item.terminal:win_valid() then
    item.terminal:hide()
  end

  if #group.items == 0 then
    group.active = nil
    group.visible = false
    group.next_number = 1
    group.page_start = 1
    group.tab = nil
    groups[group.root] = nil
    closed_placements[group.root] = final_placement
  elseif was_active then
    if was_visible and not mounted_neighbor then
      show_item(group, neighbor, focus, display_tab)
    end
  else
    local selected = active_index(group) or 1
    group.active = group.items[selected]
    recenter(group, selected)
  end

  if #group.items == 0 and was_visible then
    request_layout()
  end
  redraw()
  return true
end

local function watch_terminal(group, item)
  local function cleanup()
    vim.schedule(function()
      if not item.removing and item_index(group, item) then
        remove_item(group, item, { terminate = true })
      end
    end)
  end
  item.terminal:on("TermClose", cleanup, { buf = true })
  item.terminal:on("BufWipeout", cleanup, { buf = true })
end

function M.setup(opts)
  opts = opts or {}
  root_resolver = opts.root or root_resolver
  layout_callback = opts.on_layout_change or layout_callback
  layout_cancel_callback = opts.on_layout_cancel or layout_cancel_callback
end

function M.new(root, focus)
  local group = group_for(root, true)
  local number = group.next_number
  local previous_win = vim.api.nvim_get_current_win()
  local current_tab = vim.api.nvim_get_current_tabpage()
  local host_item, host_win = host_in_tab(group, current_tab)
  if host_item then
    group.placement = nil
    closed_placements[group.root] = nil
    host_item.terminal.win = nil
    vim.api.nvim_set_current_win(host_win)
  else
    hide_windows(group)
  end

  local terminal = Snacks.terminal.open(nil, {
    cwd = group.root,
    count = number,
    auto_close = false,
    win = {
      position = host_win and "current" or "bottom",
      height = 0.3,
      enter = focus ~= false,
      wo = { winbar = WINBAR },
      on_buf = function(win)
        vim.b[win.buf].project_terminal_root = group.root
        vim.b[win.buf].project_terminal_number = number
      end,
    },
  })
  if not terminal then
    if host_item and vim.api.nvim_win_is_valid(host_win) then
      host_item.terminal.win = host_win
    end
    return
  end

  if host_win then
    mark_bottom_terminal(terminal, host_win)
  end

  group.next_number = number + 1
  local item = { number = number, terminal = terminal, buf = terminal.buf }
  group.items[#group.items + 1] = item
  group.active = item
  group.visible = true
  group.tab = current_tab
  recenter(group, #group.items, terminal:win_valid() and vim.api.nvim_win_get_width(terminal.win) or 80)
  set_winbar(item)
  watch_terminal(group, item)

  if focus ~= false then
    focus_terminal(item)
  elseif vim.api.nvim_win_is_valid(previous_win) then
    pcall(vim.api.nvim_set_current_win, previous_win)
  end
  if not host_win then
    local restored = restore_placement(group, item)
    if not restored then
      group.placement = nil
      closed_placements[group.root] = nil
      request_layout()
    end
  end
  redraw()
  return terminal, item
end

function M.open(root, focus)
  local group = group_for(root, false)
  if not group or #group.items == 0 then
    return M.new(root, focus)
  end
  local item = group.active
  if not item or not item_index(group, item) then
    item = group.items[1]
  end
  return show_item(group, item, focus ~= false)
end

function M.hide(root)
  local group = group_for(root, false)
  if not group then
    return false
  end
  if not group.visible then
    return true
  end
  group.placement = capture_placement(group)
  hide_windows(group)
  group.visible = false
  group.tab = nil
  request_layout()
  redraw()
  return true
end

function M.switch(root, wanted, focus)
  local group = group_for(root, false)
  local index, item = item_index(group, wanted)
  if not item then
    return
  end
  recenter(group, index)
  return show_item(group, item, focus ~= false)
end

function M.confirm_close(root, wanted)
  local group = group_for(root, false)
  local _, item = item_index(group, wanted)
  if not item then
    return
  end

  local focus = item.terminal:win_valid() and vim.api.nvim_get_current_win() == item.terminal.win
  local title = terminal_title(item)
  vim.ui.select({ "Terminate", "Cancel" }, {
    prompt = ('Terminate terminal "%s"?'):format(title),
  }, function(choice)
    if choice == "Terminate" and item_index(group, item) then
      remove_item(group, item, { terminate = true, focus = focus })
    end
  end)
end

function M.page(root, direction)
  local group = group_for(root, false)
  if not group or #group.items == 0 then
    return
  end
  local current = layout(group, group.last_width or 80)
  local step = math.max(current.page_size - 1, 1)
  local max_start = math.max(#group.items - current.page_size + 1, 1)
  if direction < 0 then
    group.page_start = math.max(1, current.start - step)
  else
    group.page_start = math.min(max_start, current.start + step)
  end
  redraw()
  return group.page_start
end

function M.owns_buffer(buf)
  buf = tonumber(buf) or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  local root = vim.b[buf].project_terminal_root
  local number = vim.b[buf].project_terminal_number
  local group = type(root) == "string" and groups[normalize_root(root)] or nil
  local _, item = item_index(group, number)
  return item ~= nil and item.buf == buf, group and group.root or nil
end

local function clickable(id, highlight, text)
  return ("%%#%s#%%%d@v:lua.TerminalTabsClick@%s%%T"):format(highlight, id, status_escape(text))
end

function M.render(win)
  win = tonumber(win) or tonumber(vim.g.statusline_winid) or vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(win) then
    return ""
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local root = vim.b[buf].project_terminal_root
  local group = type(root) == "string" and groups[normalize_root(root)] or nil
  if not group or #group.items == 0 then
    click_targets[buf] = nil
    return ""
  end

  local width = vim.api.nvim_win_get_width(win)
  group.last_width = width
  local page = layout(group, width)
  group.page_start = page.start
  local targets = {}
  local parts = {}
  local function add(action, highlight, text)
    targets[#targets + 1] = action
    parts[#parts + 1] = clickable(#targets, highlight, text)
  end

  if page.left then
    add({ action = "page", root = group.root, direction = -1 }, "TabLine", " ‹ ")
  end
  for _, entry in ipairs(page.entries) do
    local highlight = entry.item == group.active and "TabLineSel" or "TabLine"
    add({ action = "switch", root = group.root, item = entry.item }, highlight, " " .. entry.title .. " ")
    add({ action = "close", root = group.root, item = entry.item }, highlight, "× ")
  end
  if page.right then
    add({ action = "page", root = group.root, direction = 1 }, "TabLine", " › ")
  end
  add({ action = "new", root = group.root }, "TabLine", " + ")
  click_targets[buf] = targets
  return table.concat(parts)
end

function M.click(minwid, _, button, _, win)
  if button ~= "l" and button ~= "left" then
    return
  end
  local mouse = vim.fn.getmousepos()
  win = tonumber(win) or (mouse and mouse.winid) or tonumber(vim.g.statusline_winid)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local target = click_targets[buf] and click_targets[buf][tonumber(minwid)] or nil
  if not target then
    return
  end
  vim.schedule(function()
    if target.action == "new" then
      M.new(target.root, true)
    elseif target.action == "switch" then
      M.switch(target.root, target.item, true)
    elseif target.action == "close" then
      M.confirm_close(target.root, target.item)
    elseif target.action == "page" then
      M.page(target.root, target.direction)
    end
  end)
end

_G.TerminalTabsClick = function(...)
  return M.click(...)
end

M._groups = groups
M._closed_placements = closed_placements
M._click_targets = click_targets
M._layout = layout
M._normalize_root = normalize_root
M._sanitize_title = sanitize_title
M._status_escape = status_escape
M._terminal_title = terminal_title
M._truncate_display = truncate_display

return M
