local TerminalTabs = require("config.terminal_tabs")

assert(rawget(_G, "Snacks") and Snacks.terminal, "Snacks must be loaded by the real config")

local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
root = TerminalTabs._normalize_root(root)
local original_select = vim.ui.select
local starting_tab = vim.api.nvim_get_current_tabpage()
local extra_tab

local function group()
  return TerminalTabs._groups[root]
end

local function visible_count()
  local count = 0
  for _, item in ipairs(group() and group().items or {}) do
    count = count + (item.terminal:win_valid() and 1 or 0)
  end
  return count
end

local function select_item(action)
  vim.ui.select = function(_, _, callback)
    callback(action)
  end
end

local function window_geometry(terminal_win)
  local geometry = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(win).relative == "" then
      local position = vim.api.nvim_win_get_position(win)
      geometry[win == terminal_win and "terminal" or win] = {
        row = position[1],
        col = position[2],
        width = vim.api.nvim_win_get_width(win),
        height = vim.api.nvim_win_get_height(win),
      }
    end
  end
  return geometry
end

local function normalized_layout(node, terminal_win)
  if node[1] == "leaf" then
    return { "leaf", node[2] == terminal_win and "terminal" or node[2] }
  end
  local normalized = { node[1], {} }
  for _, child in ipairs(node[2]) do
    normalized[2][#normalized[2] + 1] = normalized_layout(child, terminal_win)
  end
  return normalized
end

local function persistent_views(excluded_win)
  local views = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if win ~= excluded_win and vim.api.nvim_win_get_config(win).relative == "" then
      views[win] = vim.api.nvim_win_call(win, vim.fn.winsaveview)
    end
  end
  return views
end

local ok, test_error = pcall(function()
  local first = assert(TerminalTabs.new(root, false))
  assert(
    vim.tbl_isempty(vim.api.nvim_buf_get_keymap(first.buf, "t")),
    "project terminals should not intercept terminal-mode keyboard input"
  )
  vim.b[first.buf].term_title = "one"
  local second = assert(TerminalTabs.new(root, false))
  vim.b[second.buf].term_title = "two"
  local third = assert(TerminalTabs.new(root, false))
  vim.b[third.buf].term_title = "three"
  assert(#group().items == 3, "three project terminals were not created")
  assert(group().active.terminal == third, "the newest terminal did not become active")
  assert(visible_count() == 1 and third:win_valid(), "creating tabs left multiple terminal windows visible")

  TerminalTabs.render(third.win)
  local switch_id
  for id, target in ipairs(TerminalTabs._click_targets[third.buf]) do
    if target.action == "switch" and target.item.terminal == first then
      switch_id = id
      break
    end
  end
  assert(switch_id, "first terminal does not have a clickable winbar tab")
  TerminalTabs.click(switch_id, 1, "r", "", third.win)
  assert(group().active.terminal == third, "right clicking a terminal tab switched it")
  TerminalTabs.click(switch_id, 1, "l", "", third.win)
  assert(
    vim.wait(1000, function()
      return group().active.terminal == first and first:win_valid() and visible_count() == 1
    end),
    "left clicking a terminal tab did not switch the sole visible window"
  )

  TerminalTabs.render(first.win)
  local plus_id
  for id, target in ipairs(TerminalTabs._click_targets[first.buf]) do
    if target.action == "new" then
      plus_id = id
      break
    end
  end
  assert(plus_id, "terminal winbar is missing its new-tab button")
  local host_win = first.win
  local layout_before_new = vim.fn.winlayout()
  local geometry_before_new = window_geometry()
  TerminalTabs.click(plus_id, 1, "l", "", first.win)
  assert(
    vim.wait(1000, function()
      return group() and #group().items == 4 and group().active.number == 4 and visible_count() == 1
    end),
    "clicking the winbar new-tab button did not create and activate a shell"
  )
  local fourth = group().active.terminal
  assert(fourth.win == host_win, "the winbar new-tab button replaced the terminal host window")
  assert(vim.deep_equal(layout_before_new, vim.fn.winlayout()), "the winbar new-tab button changed the window tree")
  assert(vim.deep_equal(geometry_before_new, window_geometry()), "the winbar new-tab button changed window geometry")
  assert(vim.api.nvim_get_current_win() == fourth.win, "the winbar new-tab button did not focus the new shell")

  TerminalTabs.switch(root, first, true)
  assert(first.win == host_win, "switching terminal tabs replaced the terminal host window")
  assert(vim.deep_equal(layout_before_new, vim.fn.winlayout()), "switching terminal tabs changed the window tree")
  assert(vim.deep_equal(geometry_before_new, window_geometry()), "switching terminal tabs changed window geometry")
  TerminalTabs.switch(root, fourth, true)
  assert(fourth.win == host_win, "switching back did not reuse the terminal host window")

  for index, terminal in ipairs({ first, second, third, fourth }) do
    vim.b[terminal.buf].term_title = ("terminal-%d-"):format(index) .. string.rep("long", 8)
  end
  group().page_start = 1
  TerminalTabs.render(fourth.win)
  local next_page_id
  for id, target in ipairs(TerminalTabs._click_targets[fourth.buf]) do
    if target.action == "page" and target.direction == 1 then
      next_page_id = id
      break
    end
  end
  assert(next_page_id, "overflowed terminal tabs are missing forward pagination")
  TerminalTabs.click(next_page_id, 1, "l", "", fourth.win)
  assert(
    vim.wait(1000, function()
      return group().page_start > 1
    end),
    "clicking the forward pagination control did not move the terminal page"
  )
  local active_visible = false
  for _, entry in ipairs(TerminalTabs._layout(group(), vim.api.nvim_win_get_width(fourth.win)).entries) do
    active_visible = active_visible or entry.item == group().active
  end
  assert(active_visible, "terminal pagination hid the active tab")
  TerminalTabs.render(fourth.win)
  local previous_page_id
  for id, target in ipairs(TerminalTabs._click_targets[fourth.buf]) do
    if target.action == "page" and target.direction == -1 then
      previous_page_id = id
      break
    end
  end
  assert(previous_page_id, "paged terminal tabs are missing backward pagination")
  TerminalTabs.click(previous_page_id, 1, "l", "", fourth.win)
  assert(
    vim.wait(1000, function()
      return group().page_start == 1
    end),
    "clicking the backward pagination control did not restore the first page"
  )
  vim.b[first.buf].term_title = "one"
  vim.b[second.buf].term_title = "two"
  vim.b[third.buf].term_title = "three"
  vim.b[fourth.buf].term_title = "four"

  local hidden_host = fourth.win
  local layout_before_hide = normalized_layout(vim.fn.winlayout(), hidden_host)
  local geometry_before_hide = window_geometry(hidden_host)
  local views_before_hide = persistent_views(hidden_host)
  TerminalTabs.hide(root)
  assert(visible_count() == 0, "hiding the terminal panel left a terminal window visible")
  TerminalTabs.hide(root)
  assert(visible_count() == 0, "hiding an already hidden terminal exposed a terminal window")
  for _, terminal in ipairs({ first, second, third, fourth }) do
    assert(terminal:buf_valid(), "hiding the terminal panel deleted a shell buffer")
    assert(vim.fn.jobwait({ vim.bo[terminal.buf].channel }, 0)[1] == -1, "hiding the terminal panel stopped a shell")
  end
  vim.wait(150)
  local editor_win = vim.api.nvim_get_current_win()
  TerminalTabs.open(root, false)
  vim.wait(150)
  assert(group().active.terminal == fourth and fourth:win_valid(), "reopening did not restore the last active terminal")
  assert(vim.api.nvim_get_current_win() == editor_win, "PanelOpen-style terminal restore stole editor focus")
  assert(
    vim.deep_equal(layout_before_hide, normalized_layout(vim.fn.winlayout(), fourth.win)),
    "hiding and reopening the terminal changed the window tree"
  )
  assert(
    vim.deep_equal(geometry_before_hide, window_geometry(fourth.win)),
    "hiding and reopening the terminal changed window geometry"
  )
  assert(vim.deep_equal(views_before_hide, persistent_views(fourth.win)), "hiding and reopening changed editor views")

  TerminalTabs.switch(root, second, false)
  assert(second:win_valid() and visible_count() == 1, "programmatic terminal switching exposed multiple windows")
  local old_win = second.win
  vim.cmd.tabnew()
  extra_tab = vim.api.nvim_get_current_tabpage()
  local new_tab_editor = vim.api.nvim_get_current_win()
  TerminalTabs.open(root, false)
  assert(not vim.api.nvim_win_is_valid(old_win), "cross-tab restore left the terminal mounted in the old tab")
  assert(
    vim.api.nvim_win_get_tabpage(second.win) == extra_tab,
    "cross-tab restore did not mount the terminal in the current tab"
  )
  assert(vim.api.nvim_get_current_win() == new_tab_editor, "cross-tab PanelOpen-style restore stole editor focus")
  TerminalTabs.hide(root)
  vim.cmd.tabclose()
  extra_tab = nil
  assert(vim.api.nvim_get_current_tabpage() == starting_tab, "integration test did not return to its original tab")
  TerminalTabs.open(root, false)

  local prompt
  vim.ui.select = function(_, opts, callback)
    prompt = opts.prompt
    callback("Cancel")
  end
  TerminalTabs.render(second.win)
  local close_id
  for id, target in ipairs(TerminalTabs._click_targets[second.buf]) do
    if target.action == "close" and target.item.terminal == second then
      close_id = id
      break
    end
  end
  assert(close_id, "active terminal tab is missing its close button")
  TerminalTabs.click(close_id, 1, "l", "", second.win)
  -- The real shell updates term_title asynchronously. Pin the value after the
  -- mouse callback is queued so this assertion tests the confirmation UI,
  -- rather than racing the shell's next title escape sequence.
  vim.b[second.buf].term_title = "two"
  assert(
    vim.wait(1000, function()
      return prompt ~= nil
    end),
    "clicking a terminal close button did not show confirmation"
  )
  assert(prompt:find("two", 1, true), "close confirmation omitted the current terminal title")
  assert(#group().items == 4 and group().active.terminal == second, "cancelling close changed terminal state")

  select_item("Terminate")
  local close_host = second.win
  local layout_before_close = vim.fn.winlayout()
  local geometry_before_close = window_geometry()
  TerminalTabs.confirm_close(root, second)
  assert(
    vim.wait(1000, function()
      return group() and #group().items == 3 and group().active.terminal == third and visible_count() == 1
    end),
    "closing the active terminal did not prefer its right neighbor"
  )
  assert(third.win == close_host, "closing the active terminal replaced its host window")
  assert(vim.deep_equal(layout_before_close, vim.fn.winlayout()), "closing the active terminal changed the window tree")
  assert(
    vim.deep_equal(geometry_before_close, window_geometry()),
    "closing the active terminal changed window geometry"
  )

  TerminalTabs.confirm_close(root, first)
  assert(
    vim.wait(1000, function()
      return group() and #group().items == 2
    end),
    "closing an inactive terminal did not remove only that tab"
  )
  assert(group().active.terminal == third and third:win_valid(), "closing an inactive terminal changed the active tab")

  local exit_host = third.win
  local layout_before_exit = vim.fn.winlayout()
  local geometry_before_exit = window_geometry()
  vim.api.nvim_chan_send(vim.bo[third.buf].channel, "exit\n")
  assert(
    vim.wait(3000, function()
      return group() and #group().items == 1 and group().active.terminal == fourth and fourth:win_valid()
    end),
    "a shell exiting on its own did not select and show its neighbor"
  )
  assert(fourth.win == exit_host, "an exiting shell replaced the terminal host window")
  assert(vim.deep_equal(layout_before_exit, vim.fn.winlayout()), "an exiting shell changed the window tree")
  assert(vim.deep_equal(geometry_before_exit, window_geometry()), "an exiting shell changed window geometry")

  local final_host = fourth.win
  local final_layout = normalized_layout(vim.fn.winlayout(), final_host)
  local final_geometry = window_geometry(final_host)
  local final_views = persistent_views(final_host)
  local windows_with_terminal = #vim.api.nvim_tabpage_list_wins(0)
  TerminalTabs.confirm_close(root, group().active)
  assert(
    vim.wait(1000, function()
      return group() == nil
    end),
    "closing the final tab did not clear its terminal group"
  )
  assert(
    #vim.api.nvim_tabpage_list_wins(0) < windows_with_terminal,
    "closing the final tab did not restore the editor layout"
  )

  vim.wait(150)
  local restarted = assert(TerminalTabs.open(root, false))
  assert(vim.b[restarted.buf].project_terminal_number == 1, "real terminal numbering did not restart at one")
  assert(
    vim.deep_equal(final_layout, normalized_layout(vim.fn.winlayout(), restarted.win)),
    "reopening after closing every terminal changed the window tree"
  )
  assert(
    vim.deep_equal(final_geometry, window_geometry(restarted.win)),
    "reopening after closing every terminal changed window geometry"
  )
  assert(
    vim.deep_equal(final_views, persistent_views(restarted.win)),
    "reopening after closing every terminal changed editor views"
  )
  select_item("Terminate")
  TerminalTabs.confirm_close(root, 1)
  assert(
    vim.wait(1000, function()
      return group() == nil
    end),
    "restarted terminal did not close cleanly"
  )

  local unmanaged = assert(Snacks.terminal.open(nil, {
    cwd = root,
    count = 99,
    auto_close = false,
    win = { position = "bottom", enter = false },
  }))
  local unmanaged_buf = unmanaged.buf
  assert(not TerminalTabs.owns_buffer(unmanaged_buf), "an ordinary Snacks terminal entered the project terminal group")
  vim.api.nvim_chan_send(vim.bo[unmanaged_buf].channel, "exit\r")
  assert(
    vim.wait(3000, function()
      return not vim.api.nvim_buf_is_valid(unmanaged_buf)
    end),
    "managed terminal protection changed Neovim's cleanup for ordinary terminals"
  )
end)

vim.ui.select = original_select
if extra_tab and vim.api.nvim_tabpage_is_valid(extra_tab) then
  pcall(vim.api.nvim_set_current_tabpage, extra_tab)
  pcall(vim.cmd.tabclose)
end
local remaining = group()
if remaining then
  for _, item in ipairs(vim.list_slice(remaining.items)) do
    if item.terminal:buf_valid() then
      pcall(item.terminal.close, item.terminal)
    end
  end
  TerminalTabs._groups[root] = nil
end
vim.fn.delete(root, "rf")
assert(ok, test_error)

print("terminal-tabs-snacks-integration-ok")
