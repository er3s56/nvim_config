-- Exercise actual wheel input: a buffer mapping can shadow the global mouse
-- router even when the retained diff itself is still valid.
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local lines = { "# Markdown wheel regression", "" }
for i = 1, 150 do
  lines[#lines + 1] = ("Markdown paragraph %d"):format(i)
end
vim.fn.writefile(lines, root .. "/document.md")
vim.fn.writefile({ "local other = true" }, root .. "/other.lua")
assert(vim.system({ "git", "init", "-q", root }):wait().code == 0)

vim.o.columns = 160
vim.o.lines = 45
local sock = vim.fn.tempname() .. ".sock"
local chan = vim.fn.jobstart({ "nvim", "--listen", sock, "-i", "NONE", "document.md" }, {
  term = true,
  cwd = root,
  env = { TERM = "xterm-256color", NVIM = "", NVIM_LISTEN_ADDRESS = "" },
})
local rpc
local function wait_for(predicate, message)
  assert(vim.wait(10000, predicate, 50), message)
end
local function child(code)
  return vim.rpcrequest(rpc, "nvim_exec_lua", code, {})
end
local function settle()
  vim.wait(300, function()
    return false
  end, 10)
end
local function wheel(win, direction)
  local pos = child(("return vim.api.nvim_win_get_position(%d)"):format(win))
  vim.rpcrequest(rpc, "nvim_input_mouse", "wheel", direction, "", 0, pos[1] + 4, pos[2] + 8)
  settle()
end
local function top(win)
  return child(("return vim.api.nvim_win_call(%d, function() return vim.fn.line('w0') end)"):format(win))
end
local function assert_scroll(win, direction, message, hovered_win)
  local before = top(win)
  wheel(hovered_win or win, direction)
  local delta = top(win) - before
  assert(direction == "down" and delta > 0 or direction == "up" and delta < 0, message)
end
local function focus_document(win)
  child(("vim.api.nvim_set_current_win(%d); vim.cmd('normal! 40Gzt')"):format(win))
  settle()
end

local ok, err = pcall(function()
  wait_for(function()
    return vim.fn.getftype(sock) ~= ""
  end, "child did not start")
  rpc = vim.fn.sockconnect("pipe", sock, { rpc = true })
  wait_for(function()
    return child([[return package.loaded['config.activity_bar'] ~= nil
      and require('config.activity_bar').current() ~= nil]])
  end, "project panels did not open")
  child([[
    local view = require('config.activity_bar').open('git', { focus = false })
    _G.scroll_test_panel = view.content.git_state
    require('config.git_panel').refresh(scroll_test_panel.buf, { status_only = true })
  ]])
  wait_for(function()
    return child([[
      for row, entry in pairs(scroll_test_panel.entries or {}) do
        if entry.kind == 'worktree_file' and entry.path == 'document.md' then
          vim.api.nvim_set_current_win(scroll_test_panel.win)
          vim.api.nvim_win_set_cursor(scroll_test_panel.win, { row, 0 })
          vim.fn.maparg('<CR>', 'n', false, true).callback()
          return true
        end
      end
      return false
    ]])
  end, "Markdown was not listed in Git")
  wait_for(function()
    return child("return scroll_test_panel.preview_layout ~= nil")
  end, "diff did not open")
  local wins = child([[local l = scroll_test_panel.preview_layout; return { l.main_win, l.after_win }]])
  focus_document(wins[2])
  assert_scroll(wins[2], "down", "active diff did not scroll")

  child([[require('config.activity_bar').open('explorer', { focus = false })]])
  settle()
  focus_document(wins[2])
  assert_scroll(wins[2], "down", "switching to Explorer swallowed the Markdown wheel event")
  -- Hover the empty Before side of this added file while focus stays on After.
  assert_scroll(wins[2], "down", "the retained diff stopped synchronizing from its empty side", wins[1])

  child([[require('config.activity_bar').open('git', { focus = false })]])
  settle()
  focus_document(wins[2])
  assert_scroll(wins[2], "down", "the returning Git panel kept a stale wheel handler")
  assert_scroll(wins[2], "up", "the adopted diff did not scroll up")

  child([[require('config.activity_bar').open('explorer', { focus = false })]])
  child(("vim.api.nvim_set_current_win(%d); vim.cmd.edit('other.lua')"):format(wins[1]))
  wait_for(function()
    return child(("return not vim.api.nvim_win_is_valid(%d)"):format(wins[2]))
  end, "opening another file did not dismiss the retained diff")
  child("vim.cmd.edit('document.md')")
  settle()
  local editor = child("return vim.api.nvim_get_current_win()")
  assert(child("return not vim.wo.diff"), "the reopened document is still in diff mode")
  assert_scroll(editor, "down", "a former diff buffer swallowed ordinary document scrolling")
end)

if rpc then
  pcall(vim.fn.chanclose, rpc)
end
pcall(vim.fn.jobstop, chan)
vim.fn.delete(root, "rf")
assert(ok, err)
print("git-panel-scroll-ok")
