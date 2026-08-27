local TerminalTabs = require("config.terminal_tabs")
local original_select = vim.ui.select

local function normal_window(filetype)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if
      vim.api.nvim_win_get_config(win).relative == ""
      and vim.bo[vim.api.nvim_win_get_buf(win)].filetype == filetype
    then
      return win
    end
  end
end

local function normalized_layout(node, replaced_win, label)
  if node[1] == "leaf" then
    return { "leaf", node[2] == replaced_win and label or node[2] }
  end
  local normalized = { node[1], {} }
  for _, child in ipairs(node[2]) do
    normalized[2][#normalized[2] + 1] = normalized_layout(child, replaced_win, label)
  end
  return normalized
end

local function window_geometry(replaced_win, label)
  local geometry = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(win).relative == "" then
      local position = vim.api.nvim_win_get_position(win)
      geometry[win == replaced_win and label or win] = {
        row = position[1],
        col = position[2],
        width = vim.api.nvim_win_get_width(win),
        height = vim.api.nvim_win_get_height(win),
      }
    end
  end
  return geometry
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

local function snapshot(win, label)
  return {
    layout = normalized_layout(vim.fn.winlayout(), win, label),
    geometry = window_geometry(win, label),
    views = persistent_views(win),
  }
end

local function assert_restored(before, win, label, message)
  assert(
    vim.deep_equal(before.layout, normalized_layout(vim.fn.winlayout(), win, label)),
    message .. " changed the window tree"
  )
  assert(vim.deep_equal(before.geometry, window_geometry(win, label)), message .. " changed window geometry")
  assert(vim.deep_equal(before.views, persistent_views(win)), message .. " changed persistent window views")
end

vim.cmd.PanelOpen()
local root = TerminalTabs._normalize_root(LazyVim.root())
local ok, test_error = pcall(function()
  assert(
    vim.wait(3000, function()
      local group = TerminalTabs._groups[root]
      return group
        and group.active.terminal:win_valid()
        and normal_window("project_git_panel")
        and normal_window("snacks_layout_box")
    end),
    "full project panel layout did not become ready"
  )

  local group = TerminalTabs._groups[root]
  local old_terminal = group.active.terminal.win
  local terminal_snapshot = snapshot(old_terminal, "terminal")
  vim.api.nvim_set_current_win(old_terminal)
  vim.cmd.TerminalClose()
  assert(not group.visible, "TerminalClose did not hide the managed terminal")
  vim.wait(150)
  vim.cmd.TerminalOpen()
  vim.wait(150)
  assert(group.active.terminal:win_valid(), "TerminalOpen did not restore the managed terminal")
  assert_restored(terminal_snapshot, group.active.terminal.win, "terminal", "TerminalClose/TerminalOpen")

  local old_git = assert(normal_window("project_git_panel"), "Git panel disappeared during terminal restore")
  local git_snapshot = snapshot(old_git, "git")
  vim.cmd.GitPanelClose()
  assert(
    vim.wait(1000, function()
      return not vim.api.nvim_win_is_valid(old_git)
    end),
    "GitPanelClose did not close the Git panel"
  )
  vim.cmd.GitPanelOpen()
  assert(
    vim.wait(3000, function()
      return normal_window("project_git_panel") ~= nil
    end),
    "GitPanelOpen did not restore the Git panel"
  )
  vim.wait(150)
  assert_restored(git_snapshot, normal_window("project_git_panel"), "git", "GitPanelClose/GitPanelOpen")

  local old_explorer = assert(normal_window("snacks_layout_box"), "Explorer disappeared during Git restore")
  local git = assert(normal_window("project_git_panel"))
  local explorer_snapshot = snapshot(old_explorer, "explorer")
  vim.cmd.ExplorerClose()
  assert(
    vim.wait(1000, function()
      return not vim.api.nvim_win_is_valid(old_explorer)
    end),
    "ExplorerClose did not close Explorer"
  )
  assert(vim.api.nvim_win_is_valid(git), "ExplorerClose also closed the Git panel")
  vim.wait(150)
  vim.cmd.ExplorerOpen()
  assert(
    vim.wait(3000, function()
      return normal_window("snacks_layout_box") ~= nil
    end),
    "ExplorerOpen did not restore Explorer"
  )
  vim.wait(150)
  assert(vim.api.nvim_win_is_valid(git), "ExplorerOpen replaced the existing Git panel")
  assert_restored(explorer_snapshot, normal_window("snacks_layout_box"), "explorer", "ExplorerClose/ExplorerOpen")

  old_terminal = group.active.terminal.win
  terminal_snapshot = snapshot(old_terminal, "terminal")
  vim.api.nvim_set_current_win(old_terminal)
  vim.cmd.PanelClose()
  assert(not group.visible, "PanelClose from a terminal did not hide the managed terminal")
  vim.wait(150)
  vim.cmd.PanelOpen()
  assert(
    vim.wait(3000, function()
      return group.active.terminal:win_valid()
    end),
    "PanelOpen did not restore a terminal closed through PanelClose"
  )
  vim.wait(150)
  assert_restored(terminal_snapshot, group.active.terminal.win, "terminal", "terminal PanelClose/PanelOpen")

  old_git = assert(normal_window("project_git_panel"))
  git_snapshot = snapshot(old_git, "git")
  vim.api.nvim_set_current_win(old_git)
  vim.cmd.PanelClose()
  assert(
    vim.wait(1000, function()
      return not vim.api.nvim_win_is_valid(old_git)
    end),
    "PanelClose from Git did not close the Git panel"
  )
  vim.cmd.PanelOpen()
  assert(
    vim.wait(3000, function()
      return normal_window("project_git_panel") ~= nil
    end),
    "PanelOpen did not restore Git closed through PanelClose"
  )
  vim.wait(150)
  assert_restored(git_snapshot, normal_window("project_git_panel"), "git", "Git PanelClose/PanelOpen")

  old_explorer = assert(normal_window("snacks_layout_box"))
  git = assert(normal_window("project_git_panel"))
  explorer_snapshot = snapshot(old_explorer, "explorer")
  local explorer = assert(Snacks.picker.get({ source = "explorer" })[1])
  local explorer_list_win = assert(explorer.list and explorer.list.win and explorer.list.win.win)
  assert(vim.api.nvim_win_is_valid(explorer_list_win), "Explorer list window is not ready for PanelClose")
  vim.api.nvim_set_current_win(explorer_list_win)
  vim.cmd.PanelClose()
  assert(
    vim.wait(1000, function()
      return not vim.api.nvim_win_is_valid(old_explorer)
    end),
    "PanelClose from Explorer did not close Explorer"
  )
  assert(vim.api.nvim_win_is_valid(git), "PanelClose from Explorer also closed the Git panel")
  vim.cmd.PanelOpen()
  assert(
    vim.wait(3000, function()
      return normal_window("snacks_layout_box") ~= nil
    end),
    "PanelOpen did not restore Explorer closed through PanelClose"
  )
  vim.wait(150)
  assert(vim.api.nvim_win_is_valid(git), "PanelOpen replaced Git while restoring Explorer")
  assert_restored(explorer_snapshot, normal_window("snacks_layout_box"), "explorer", "Explorer PanelClose/PanelOpen")

  old_terminal = group.active.terminal.win
  terminal_snapshot = snapshot(old_terminal, "terminal")
  vim.ui.select = function(_, _, callback)
    callback("Terminate")
  end
  TerminalTabs.confirm_close(root, group.active)
  assert(
    vim.wait(1000, function()
      return TerminalTabs._groups[root] == nil
    end),
    "closing the final terminal did not clear its project group"
  )
  vim.wait(150)
  vim.cmd.TerminalOpen()
  assert(
    vim.wait(3000, function()
      group = TerminalTabs._groups[root]
      return group and group.active.terminal:win_valid()
    end),
    "TerminalOpen did not recreate a terminal after every tab was closed"
  )
  vim.wait(150)
  assert_restored(
    terminal_snapshot,
    group.active.terminal.win,
    "terminal",
    "closing every terminal followed by TerminalOpen"
  )
end)

vim.ui.select = original_select
local group = TerminalTabs._groups[root]
if group then
  for _, item in ipairs(group.items) do
    item.removing = true
    if item.terminal:buf_valid() then
      pcall(item.terminal.close, item.terminal)
    end
  end
  TerminalTabs._groups[root] = nil
end
pcall(vim.cmd.GitPanelClose)
pcall(vim.cmd.ExplorerClose)
assert(ok, test_error)

print("panel-layout-integration-ok")
