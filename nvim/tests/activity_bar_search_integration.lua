local ActivityBar = require("config.activity_bar")

assert(vim.fn.executable("rg") == 1, "Search integration test requires ripgrep")

local root = vim.fn.tempname()
local visible = vim.fs.joinpath(root, "visible.txt")
local other = vim.fs.joinpath(root, "other.txt")
local hidden = vim.fs.joinpath(root, ".hidden.txt")
local ignored = vim.fs.joinpath(root, "ignored.txt")
vim.fn.mkdir(root, "p")
assert(vim.fn.writefile({ "visible header", "needle visible" }, visible) == 0)
assert(vim.fn.writefile({ "needle other first", "other middle", "needle other last" }, other) == 0)
assert(vim.fn.writefile({ "needle hidden" }, hidden) == 0)
assert(vim.fn.writefile({ "needle ignored" }, ignored) == 0)
assert(vim.fn.writefile({ "ignored.txt" }, vim.fs.joinpath(root, ".gitignore")) == 0)
assert(vim.system({ "git", "-C", root, "init", "-q" }):wait().code == 0)

local function result_files(picker)
  local files = {}
  for index = 1, picker.list:count() do
    local item = picker.list:get(index)
    if item and item.file then
      files[vim.fs.basename(item.file)] = index
    end
  end
  return files
end

local function result_index(picker, basename, line)
  for index = 1, picker.list:count() do
    local item = picker.list:get(index)
    if
      item
      and item.file
      and vim.fs.basename(item.file) == basename
      and (not line or item.pos and item.pos[1] == line)
    then
      return index
    end
  end
end

local function wait_for_results(wanted_hidden)
  return vim.wait(3000, function()
    local state = ActivityBar.current()
    local picker = state and state.content and state.content.picker
    if not picker or picker.closed or not picker.list.win:valid() then
      return false
    end
    local files = result_files(picker)
    return files["visible.txt"] ~= nil
      and (files[".hidden.txt"] ~= nil) == wanted_hidden
      and files["ignored.txt"] == nil
  end)
end

local original_cwd = vim.fn.getcwd(0)
local ok, test_error = pcall(function()
  vim.cmd.cd(vim.fn.fnameescape(root))
  ActivityBar.setup()
  local state = ActivityBar.open("explorer", { focus = false })
  assert(
    vim.wait(3000, function()
      return state.content and state.content.kind == "explorer" and ActivityBar._content_root(state.content)
    end),
    "initial Explorer did not become ready"
  )
  local editor_win = assert(ActivityBar.editor_window())
  vim.api.nvim_win_call(editor_win, function()
    vim.cmd.edit(vim.fn.fnameescape(visible))
  end)
  local visible_buf = vim.api.nvim_win_get_buf(editor_win)
  assert(vim.bo[visible_buf].buflisted, "initial editor file is not listed for Bufferline")
  state.search.query = "needle"
  ActivityBar.open("search", { focus = false })
  assert(wait_for_results(false), "Search did not find visible project text or respect ignore rules")

  state = ActivityBar.current()
  local picker = assert(state.content.picker)
  assert(picker.input.filter.search == "needle", "Search did not restore its query")
  assert(picker.opts.hidden == false, "Search unexpectedly included hidden files by default")
  assert(picker.opts.ignored == false, "Search disabled .gitignore by default")
  local ignored_mapping = vim.api.nvim_buf_call(picker.input.win.buf, function()
    return vim.fn.maparg("<M-i>", "n", false, true)
  end)
  assert(
    ignored_mapping.desc == ".gitignore is always respected in project Search",
    "Search still exposes the ignored-file toggle"
  )
  assert(
    vim.wo[picker.input.win.win].winbar:find("ActivityBarSearchHiddenClick", 1, true),
    "Search input has no clickable hidden-file button: " .. vim.inspect(vim.wo[picker.input.win.win].winbar)
  )

  ActivityBar.toggle_search_hidden(state.tab)
  assert(wait_for_results(true), "hidden-file button did not refresh Search results")
  picker = ActivityBar.current().content.picker
  assert(picker.opts.ignored == false, "hidden-file toggle also disabled .gitignore")
  assert(vim.wo[picker.input.win.win].winbar:find("Hidden: on", 1, true), "hidden button did not show active state")

  local files = result_files(picker)
  local visible_index = assert(files["visible.txt"])
  vim.api.nvim_set_current_win(picker.list.win.win)
  assert(
    vim.wait(1000, function()
      return picker.preview.win:valid()
    end),
    "focusing Search did not restore its central preview"
  )
  picker.list:view(visible_index, math.max(visible_index - 1, 1), true)
  picker:show_preview()
  assert(
    vim.wait(1000, function()
      return picker.preview.main == ActivityBar.editor_window() and picker.preview.win:valid()
    end),
    "single-result selection did not preview in the central editor"
  )
  local saved_cursor, saved_top = picker.list.cursor, picker.list.top

  ActivityBar.open("explorer", { focus = false })
  assert(
    vim.wait(3000, function()
      local current = ActivityBar.current()
      return current.content and current.content.kind == "explorer" and ActivityBar._content_root(current.content)
    end),
    "Explorer did not replace Search"
  )
  ActivityBar.open("search", { focus = false })
  assert(wait_for_results(true), "returning to Search did not restore hidden results")
  picker = ActivityBar.current().content.picker
  assert(picker.input.filter.search == "needle", "returning to Search lost the query")
  assert(
    vim.wait(1000, function()
      return picker.list.cursor == saved_cursor and picker.list.top == saved_top
    end),
    "returning to Search lost selection or scroll position"
  )

  picker.list:view(assert(result_index(picker, "visible.txt", 2)), nil, true)
  vim.api.nvim_set_current_win(picker.list.win.win)
  picker:action("confirm")
  assert(
    vim.wait(1000, function()
      local win = ActivityBar.editor_window()
      return win == editor_win
        and vim.api.nvim_win_get_buf(win) == visible_buf
        and vim.api.nvim_win_get_cursor(win)[1] == 2
    end),
    "same-file Search result did not reuse its editor buffer and jump in place"
  )
  assert(
    not picker.closed and ActivityBar._content_root(ActivityBar.current().content),
    "opening a result closed Search"
  )

  picker.list:view(assert(result_index(picker, "other.txt", 1)), nil, true)
  vim.api.nvim_set_current_win(picker.list.win.win)
  picker:action("confirm")
  local other_buf
  assert(
    vim.wait(1000, function()
      local win = ActivityBar.editor_window()
      if win ~= editor_win or vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)) ~= other then
        return false
      end
      other_buf = vim.api.nvim_win_get_buf(win)
      return vim.api.nvim_win_get_cursor(win)[1] == 1
    end),
    "different-file Search result did not open in the shared editor"
  )
  assert(other_buf ~= visible_buf, "different Search files unexpectedly reused one buffer")
  assert(vim.bo[other_buf].buflisted, "different Search file was not added as a Bufferline tab")
  assert(
    vim.api.nvim_buf_is_valid(visible_buf) and vim.bo[visible_buf].buflisted,
    "opening another result removed the prior Bufferline tab"
  )

  picker.list:view(assert(result_index(picker, "other.txt", 3)), nil, true)
  vim.api.nvim_set_current_win(picker.list.win.win)
  picker:action("confirm")
  assert(
    vim.wait(1000, function()
      return ActivityBar.editor_window() == editor_win
        and vim.api.nvim_win_get_buf(editor_win) == other_buf
        and vim.api.nvim_win_get_cursor(editor_win)[1] == 3
    end),
    "second result in the same file did not reuse its Bufferline tab and jump in place"
  )
end)

pcall(ActivityBar.close)
vim.cmd.cd(vim.fn.fnameescape(original_cwd))
pcall(require("gitsigns").detach_all)
for _, buf in ipairs(vim.api.nvim_list_bufs()) do
  local name = vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) or ""
  if name:sub(1, #root + 1) == root .. "/" then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end
-- Let any GitSigns jobs spawned by the final buffer transition finish while
-- their temporary repository still exists.
vim.wait(200)
vim.fn.delete(root, "rf")
assert(ok, test_error)

print("activity-bar-search-integration-ok")
