local TerminalTabs = require("config.terminal_tabs")

local function assert_equal(expected, actual, message)
  if not vim.deep_equal(expected, actual) then
    error(("%s\nexpected: %s\nactual:   %s"):format(message, vim.inspect(expected), vim.inspect(actual)))
  end
end

local root = vim.fn.tempname()
local other_root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.fn.mkdir(other_root, "p")
root = TerminalTabs._normalize_root(root)
other_root = TerminalTabs._normalize_root(other_root)

local original_open = Snacks.terminal.open
local original_select = vim.ui.select
local original_buf = vim.api.nvim_get_current_buf()
local created = {}

local function fake_open(_, opts)
  local terminal = {
    buf = vim.api.nvim_create_buf(false, true),
    opts = opts.win,
    events = {},
  }
  function terminal:buf_valid()
    return self.buf and vim.api.nvim_buf_is_valid(self.buf)
  end
  function terminal:win_valid()
    return false
  end
  function terminal:hide()
    return self
  end
  function terminal:show()
    return self
  end
  function terminal:close()
    if self:buf_valid() then
      vim.api.nvim_buf_delete(self.buf, { force = true })
    end
    return self
  end
  function terminal:on(event, callback)
    self.events[event] = callback
    return self
  end
  opts.win.on_buf(terminal)
  created[#created + 1] = terminal
  return terminal
end

local ok, test_error = pcall(function()
  Snacks.terminal.open = fake_open

  local first = assert(TerminalTabs.new(root, false))
  local second = assert(TerminalTabs.new(root, false))
  local isolated = assert(TerminalTabs.new(other_root, false))
  local group = assert(TerminalTabs._groups[root])
  local other = assert(TerminalTabs._groups[other_root])
  assert_equal(
    { 1, 2 },
    vim.tbl_map(function(item)
      return item.number
    end, group.items),
    "project terminal numbering or insertion order changed"
  )
  assert_equal(1, other.items[1].number, "a second project did not receive an isolated terminal sequence")
  assert(first.buf ~= isolated.buf, "different projects shared a terminal buffer")

  vim.b[first.buf].term_title = "  build\t100%\n中文  "
  assert_equal(
    "build 100% 中文",
    TerminalTabs._terminal_title(group.items[1]),
    "automatic terminal title was not sanitized"
  )
  assert_equal(
    "Terminal 2",
    TerminalTabs._terminal_title(group.items[2]),
    "missing title did not use its terminal number"
  )
  local shortened = TerminalTabs._truncate_display("很长的终端标题abcdef", 10)
  assert(vim.fn.strdisplaywidth(shortened) <= 10, "Unicode terminal title overflowed its display width")
  assert(shortened:sub(-#"…") == "…", "truncated terminal title is missing its ellipsis")
  assert_equal("100%% ready", TerminalTabs._status_escape("100% ready"), "winbar percent escaping changed")

  local items = {}
  for number = 1, 8 do
    items[number] = { number = number, terminal = {}, buf = -1 }
  end
  local narrow_group = { items = items, active = items[8], page_start = 1 }
  local page = TerminalTabs._layout(narrow_group, 28)
  assert(page.right, "narrow terminal tabs did not expose forward pagination")
  assert(
    vim.tbl_contains(
      vim.tbl_map(function(entry)
        return entry.item
      end, page.entries),
      items[8]
    ),
    "narrow terminal tabs hid the active terminal"
  )

  vim.api.nvim_win_set_buf(0, second.buf)
  local winbar = TerminalTabs.render(vim.api.nvim_get_current_win())
  assert(winbar:find("TerminalTabsClick", 1, true), "winbar does not contain mouse callbacks")
  assert(winbar:find("%%", 1, true), "winbar did not escape the percent sign in a title")
  assert(winbar:find("TabLineSel", 1, true), "winbar does not distinguish the active terminal")
  local before_right_click = #group.items
  TerminalTabs.click(#TerminalTabs._click_targets[second.buf], 1, "r", "", vim.api.nvim_get_current_win())
  assert_equal(before_right_click, #group.items, "a non-left winbar click changed terminal state")
  vim.api.nvim_win_set_buf(0, original_buf)

  local prompt
  vim.ui.select = function(_, opts, callback)
    prompt = opts.prompt
    callback("Cancel")
  end
  TerminalTabs.confirm_close(root, group.items[1])
  assert(prompt:find("build 100%% 中文"), "termination confirmation did not include the terminal title")
  assert_equal(2, #group.items, "cancelling termination changed the terminal group")

  vim.ui.select = function(_, _, callback)
    callback("Terminate")
  end
  TerminalTabs.confirm_close(root, 1)
  assert_equal(
    { 2 },
    vim.tbl_map(function(item)
      return item.number
    end, group.items),
    "terminating an inactive tab changed terminal order"
  )
  TerminalTabs.confirm_close(root, 2)
  assert(TerminalTabs._groups[root] == nil, "closing the final terminal did not clear the project group")

  local restarted = assert(TerminalTabs.new(root, false))
  assert_equal(
    1,
    vim.b[restarted.buf].project_terminal_number,
    "terminal numbering did not reset after the group emptied"
  )
  TerminalTabs.confirm_close(root, 1)
  TerminalTabs.confirm_close(other_root, 1)
end)

Snacks.terminal.open = original_open
vim.ui.select = original_select
if vim.api.nvim_buf_is_valid(original_buf) then
  pcall(vim.api.nvim_win_set_buf, 0, original_buf)
end
for _, terminal in ipairs(created) do
  if terminal:buf_valid() then
    pcall(vim.api.nvim_buf_delete, terminal.buf, { force = true })
  end
end
TerminalTabs._groups[root] = nil
TerminalTabs._groups[other_root] = nil
vim.fn.delete(root, "rf")
vim.fn.delete(other_root, "rf")
assert(ok, test_error)

assert(type(_G.TerminalTabsClick) == "function", "global terminal winbar callback is missing")
print("terminal-tabs-ok")
