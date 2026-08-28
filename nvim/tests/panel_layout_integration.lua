local ActivityBar = require("config.activity_bar")
local TerminalTabs = require("config.terminal_tabs")

local function geometry(win)
  local position = vim.api.nvim_win_get_position(win)
  return {
    row = position[1],
    col = position[2],
    width = vim.api.nvim_win_get_width(win),
    height = vim.api.nvim_win_get_height(win),
  }
end

local function normal_windows(tab)
  return vim.tbl_filter(function(win)
    return vim.api.nvim_win_get_config(win).relative == ""
  end, vim.api.nvim_tabpage_list_wins(tab or 0))
end

local function wait_for_view(kind)
  return vim.wait(3000, function()
    local state = ActivityBar.current()
    return state and state.content and state.content.kind == kind and ActivityBar._content_root(state.content) ~= nil
  end)
end

vim.cmd.PanelOpen()
local root = TerminalTabs._normalize_root(LazyVim.root())
local original_select = vim.ui.select
local shared_editor_buf
local ok, test_error = pcall(function()
  assert(wait_for_view("explorer"), "default Explorer sidebar did not become ready")
  assert(
    vim.wait(3000, function()
      local terminal_group = TerminalTabs._groups[root]
      return terminal_group and terminal_group.active.terminal:win_valid()
    end),
    "default project terminal did not become ready"
  )
  vim.wait(150)

  local state = ActivityBar.current()
  local terminal_group = assert(TerminalTabs._groups[root])
  local activity_win = state.activity.win
  local explorer_win = assert(ActivityBar._content_root(state.content))
  local editor_win = assert(ActivityBar.editor_window())
  local terminal_win = terminal_group.active.terminal.win
  shared_editor_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(shared_editor_buf, 0, -1, false, { "shared editor sentinel" })
  vim.api.nvim_win_set_buf(editor_win, shared_editor_buf)
  assert(vim.bo[state.activity.buf].filetype == "activity_bar", "Activity Bar buffer has the wrong filetype")
  assert(vim.api.nvim_win_get_width(activity_win) == 3, "Activity Bar is not exactly three columns")
  assert(#normal_windows() == 4, "default layout does not have exactly four normal windows")
  assert(
    vim.deep_equal(vim.fn.winlayout(), {
      "row",
      {
        { "leaf", activity_win },
        { "leaf", explorer_win },
        { "col", { { "leaf", editor_win }, { "leaf", terminal_win } } },
      },
    }),
    "default layout is not Activity Bar, Explorer, editor over terminal: " .. vim.inspect(vim.fn.winlayout())
  )

  local editor_geometry = geometry(editor_win)
  local terminal_geometry = geometry(terminal_win)
  vim.cmd.SearchPanelOpen()
  assert(wait_for_view("search"), "Search sidebar did not replace Explorer")
  vim.wait(100)
  state = ActivityBar.current()
  assert(not vim.api.nvim_win_is_valid(explorer_win), "Explorer survived after switching to Search")
  assert(state.activity.win == activity_win, "switching views replaced the Activity Bar window")
  assert(
    ActivityBar.editor_window() == editor_win and vim.api.nvim_win_get_buf(editor_win) == shared_editor_buf,
    "Search did not share the existing central editor and buffer"
  )
  assert(
    vim.deep_equal(editor_geometry, geometry(editor_win)),
    "Search changed editor geometry: "
      .. vim.inspect({ before = editor_geometry, after = geometry(editor_win), layout = vim.fn.winlayout() })
  )
  assert(
    vim.deep_equal(terminal_geometry, geometry(terminal_win)),
    "Search changed terminal geometry: " .. vim.inspect({ before = terminal_geometry, after = geometry(terminal_win) })
  )
  assert(#normal_windows() == 4, "Search created more than one sidebar slot")

  local search_win = assert(ActivityBar._content_root(state.content))
  vim.cmd.GitPanelOpen()
  assert(wait_for_view("git"), "Git sidebar did not replace Search")
  assert(
    vim.wait(3000, function()
      local current = ActivityBar.current()
      return not current.content.git_state
        or (current.content.git_state.changes ~= nil and current.content.git_state.commits ~= nil)
    end),
    "Git sidebar did not finish loading"
  )
  vim.wait(100)
  state = ActivityBar.current()
  local git_win = assert(ActivityBar._content_root(state.content))
  assert(not vim.api.nvim_win_is_valid(search_win), "Search survived after switching to Git")
  assert(state.activity.win == activity_win, "Git switching replaced the Activity Bar window")
  assert(
    ActivityBar.editor_window() == editor_win and vim.api.nvim_win_get_buf(editor_win) == shared_editor_buf,
    "Git did not share the existing central editor and buffer"
  )
  assert(vim.deep_equal(editor_geometry, geometry(editor_win)), "Git changed editor geometry")
  assert(vim.deep_equal(terminal_geometry, geometry(terminal_win)), "Git changed terminal geometry")
  assert(#normal_windows() == 4, "Git created more than one sidebar slot")

  local git_geometry = geometry(git_win)
  vim.cmd.ActivityBarToggle("git")
  assert(
    vim.wait(1000, function()
      return not vim.api.nvim_win_is_valid(git_win)
    end),
    "repeated Git activation did not collapse the sidebar"
  )
  assert(ActivityBar.current().collapsed, "collapsed state was not recorded")
  assert(#normal_windows() == 3, "collapsing the sidebar removed or leaked another window")
  assert(vim.api.nvim_win_get_width(editor_win) > editor_geometry.width, "collapsed sidebar did not expand the editor")

  vim.cmd.ActivityBarToggle("git")
  assert(wait_for_view("git"), "repeated Git activation did not restore the sidebar")
  vim.wait(100)
  state = ActivityBar.current()
  git_win = assert(ActivityBar._content_root(state.content))
  assert(vim.deep_equal(git_geometry, geometry(git_win)), "restored Git sidebar lost its geometry")
  assert(vim.deep_equal(editor_geometry, geometry(editor_win)), "restored Git sidebar changed editor geometry")
  assert(vim.deep_equal(terminal_geometry, geometry(terminal_win)), "restored Git sidebar changed terminal geometry")

  vim.cmd.ExplorerOpen()
  assert(wait_for_view("explorer"), "ExplorerOpen did not select Explorer")
  vim.cmd.GitPanelClose()
  vim.wait(100)
  assert(
    ActivityBar.current().view == "explorer" and not ActivityBar.current().collapsed,
    "GitPanelClose collapsed a different active view"
  )
  local current_content = assert(ActivityBar._content_root(ActivityBar.current().content))
  vim.cmd.ExplorerClose()
  assert(
    vim.wait(1000, function()
      return not vim.api.nvim_win_is_valid(current_content)
    end),
    "ExplorerClose did not collapse an active Explorer"
  )
  vim.cmd.PanelOpen()
  assert(wait_for_view("explorer"), "PanelOpen did not restore the selected sidebar")

  terminal_group = assert(TerminalTabs._groups[root])
  terminal_win = terminal_group.active.terminal.win
  vim.api.nvim_set_current_win(editor_win)
  assert(
    ActivityBar._queue_terminal_insert({ winid = terminal_win }),
    "terminal mouse fallback did not recognize the managed terminal"
  )
  assert(
    vim.wait(1000, function()
      return vim.api.nvim_get_current_win() == terminal_win
    end),
    "terminal mouse fallback did not focus the terminal"
  )
  assert(
    not ActivityBar._queue_terminal_insert({ winid = editor_win }),
    "terminal mouse fallback consumed a non-terminal window"
  )
  vim.api.nvim_set_current_win(terminal_win)
  vim.cmd.PanelClose()
  assert(not terminal_group.visible, "PanelClose in a terminal did not hide the terminal")
  vim.cmd.PanelOpen()
  assert(
    vim.wait(3000, function()
      return terminal_group.active.terminal:win_valid()
    end),
    "PanelOpen did not restore the terminal"
  )

  state = ActivityBar.current()
  local sidebar_win = assert(ActivityBar._content_root(state.content))
  local sidebar_focus = state.content.picker.list.win.win
  vim.api.nvim_set_current_win(sidebar_focus)
  vim.cmd.PanelClose()
  assert(
    vim.wait(1000, function()
      return not vim.api.nvim_win_is_valid(sidebar_win)
    end),
    "PanelClose in the sidebar did not collapse it"
  )

  vim.cmd.PanelOpen()
  assert(wait_for_view("explorer"), "PanelOpen did not restore Explorer after PanelClose")
  local first_tab = vim.api.nvim_get_current_tabpage()
  local first_state = ActivityBar.current()
  vim.cmd.tabnew()
  local second_tab = vim.api.nvim_get_current_tabpage()
  local second_state = ActivityBar.open("explorer", { focus = false, tab = second_tab })
  assert(
    vim.wait(3000, function()
      return second_state.content
        and second_state.content.kind == "explorer"
        and ActivityBar._content_root(second_state.content)
    end),
    "new tab did not receive its default Explorer view"
  )
  assert(second_state.tab ~= first_state.tab, "new tab reused the first tab state")
  assert(second_state.activity.win ~= first_state.activity.win, "new tab reused the first Activity Bar window")
  second_state.search.query = "second-tab-only"
  ActivityBar.open("search", { focus = false, tab = second_tab })
  assert(
    vim.wait(3000, function()
      return second_state.content
        and second_state.content.kind == "search"
        and ActivityBar._content_root(second_state.content)
    end),
    "second tab could not select its own Search view"
  )
  ActivityBar.close({ tab = second_tab })
  assert(second_state.collapsed, "second tab did not retain its own collapsed state")
  vim.api.nvim_set_current_tabpage(first_tab)
  assert(first_state.view == "explorer" and not first_state.collapsed, "second tab state leaked into the first tab")
  assert(first_state.search.query ~= second_state.search.query, "Search state leaked between tabs")
  vim.api.nvim_set_current_tabpage(second_tab)
  vim.cmd.tabclose()
  assert(vim.api.nvim_get_current_tabpage() == first_tab, "closing the second tab did not return to the first")
  assert(ActivityBar.current().activity.win == first_state.activity.win, "first tab Activity Bar state was lost")

  local function activity_mouse(row)
    local position = vim.fn.screenpos(activity_win, row, 1)
    return { winid = activity_win, line = row, screenrow = position.row }
  end

  vim.api.nvim_set_current_win(editor_win)
  assert(
    not ActivityBar._handle_mouse({ winid = editor_win, line = 1, screenrow = 1 }),
    "non-Activity mouse hit was consumed"
  )
  assert(ActivityBar._handle_mouse(activity_mouse(2)), "editor-originated first click did not hit Search")
  assert(wait_for_view("search"), "editor-originated Activity Bar click did not open Search")
  terminal_group = assert(TerminalTabs._groups[root])
  terminal_win = terminal_group.active.terminal.win
  vim.api.nvim_set_current_win(terminal_win)
  assert(ActivityBar._handle_mouse(activity_mouse(3)), "terminal-originated first click did not hit Git")
  assert(wait_for_view("git"), "terminal-originated Activity Bar click did not open Git")

  ActivityBar.open("search", { focus = false })
  ActivityBar.open("explorer", { focus = false })
  ActivityBar.open("git", { focus = false })
  assert(wait_for_view("git"), "rapid view switching did not settle on the final Git request")
  vim.wait(100)
  assert(#normal_windows() == 4, "rapid view switching leaked a sidebar window: " .. vim.inspect(vim.fn.winlayout()))
  assert(ActivityBar.current().activity.win == activity_win, "rapid switching replaced the Activity Bar")

  ActivityBar.open("search", { focus = false })
  assert(wait_for_view("search"), "Search was not ready for responsive-layout testing")
  local old_columns = vim.o.columns
  vim.o.columns = 55
  ActivityBar.reflow()
  assert(ActivityBar.current().responsive_hidden, "narrow UI did not hide the sidebar temporarily")
  assert(not ActivityBar._content_root(ActivityBar.current().content), "narrow UI left sidebar content visible")
  assert(
    vim.wait(2000, function()
      return vim.api.nvim_win_get_width(activity_win) == 3
        and vim.deep_equal(vim.fn.winlayout(), {
          "row",
          {
            { "leaf", activity_win },
            { "col", { { "leaf", editor_win }, { "leaf", terminal_win } } },
          },
        })
    end),
    "responsive sidebar close moved or widened the Activity Bar"
  )
  vim.o.columns = old_columns
  ActivityBar.reflow()
  assert(wait_for_view("search"), "wider UI did not restore the responsive-hidden view")
  local restored_sidebar = assert(ActivityBar._content_root(ActivityBar.current().content))
  assert(vim.api.nvim_win_get_width(activity_win) == 3, "responsive restore widened the Activity Bar")
  local restored_search = assert(ActivityBar.current().content.picker)
  assert(
    vim.wo[restored_search.input.win.win].winbar:find("ActivityBarSearchHiddenClick", 1, true),
    "responsive restore lost the clickable Search hidden-file button"
  )
  assert(
    vim.deep_equal(vim.fn.winlayout(), {
      "row",
      {
        { "leaf", activity_win },
        { "leaf", restored_sidebar },
        { "col", { { "leaf", editor_win }, { "leaf", terminal_win } } },
      },
    }),
    "responsive restore did not keep Activity Bar at the far left: " .. vim.inspect(vim.fn.winlayout())
  )

  for _, mapping in ipairs(vim.api.nvim_get_keymap("t")) do
    if mapping.desc == "Activate Activity Bar item" then
      assert(mapping.lhs == "<LeftMouse>", "Activity Bar added a terminal keyboard mapping")
    end
  end
end)

vim.ui.select = original_select
local terminal_group = TerminalTabs._groups[root]
if terminal_group then
  for _, item in ipairs(terminal_group.items) do
    item.removing = true
    if item.terminal:buf_valid() then
      pcall(item.terminal.close, item.terminal)
    end
  end
  TerminalTabs._groups[root] = nil
end
pcall(ActivityBar.close)
if shared_editor_buf and vim.api.nvim_buf_is_valid(shared_editor_buf) then
  pcall(vim.api.nvim_buf_delete, shared_editor_buf, { force = true })
end
assert(ok, test_error)

print("panel-layout-integration-ok")
