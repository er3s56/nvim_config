-- Check the terminal's visible viewport, not just whether its buffer contains
-- a prompt. Starting with a file makes the sidebar/terminal layout settle in
-- a different order from a dashboard-only start.
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.fn.writefile({ "local answer = 42" }, root .. "/main.lua")
assert(vim.system({ "git", "-C", root, "init", "-q" }):wait().code == 0)
local socket = root .. "/nvim.sock"
vim.o.columns, vim.o.lines = 160, 44
local chan = vim.fn.jobstart({ "nvim", "--listen", socket, root .. "/main.lua" }, {
  term = true,
  cwd = root,
  env = { TERM = "xterm-256color", NVIM = "", NVIM_LISTEN_ADDRESS = "" },
})
assert(chan > 0)
local rpc
local ok, err = xpcall(function()
  assert(vim.wait(15000, function()
    return vim.fn.getftype(socket) == "socket"
  end))
  rpc = vim.fn.sockconnect("pipe", socket, { rpc = true })
  local function child(code)
    return vim.rpcrequest(rpc, "nvim_exec_lua", code, {})
  end
  assert(vim.wait(15000, function()
    local good, ready = pcall(
      child,
      [[
      local ok,a=pcall(require,'config.activity_bar'); if not ok then return false end
      local s=a.current(); if not (s and s.content) then return false end
      for _,w in ipairs(vim.api.nvim_list_wins()) do
        local b=vim.api.nvim_win_get_buf(w)
        if vim.bo[b].buftype=='terminal' then
          for _,line in ipairs(vim.api.nvim_buf_get_lines(b,0,-1,false)) do if line~='' then return true end end
        end
      end
      return false
    ]]
    )
    return good and ready
  end))
  vim.wait(700)
  local prompt = child([[
    for _,w in ipairs(vim.api.nvim_list_wins()) do
      local b=vim.api.nvim_win_get_buf(w)
      if vim.bo[b].buftype=='terminal' then
        for row,line in ipairs(vim.api.nvim_buf_get_lines(b,0,-1,false)) do
          if line~='' then return {text=line,screen=vim.fn.screenpos(w,row,1),view=vim.api.nvim_win_call(w,vim.fn.winsaveview)} end
        end
      end
    end
  ]])
  assert(prompt and prompt.screen.row > 0, "startup hid the shell prompt: " .. vim.inspect(prompt))

  local previous = child("return vim.api.nvim_get_current_win()")
  child("require('config.terminal_tabs').new(nil,false)")
  vim.wait(500)
  local mode = child("return {mode=vim.api.nvim_get_mode().mode,win=vim.api.nvim_get_current_win()}")
  assert(mode.win == previous, "unfocused terminal creation stole editor focus")
  assert(mode.mode == "n", "unfocused terminal creation started insert mode in the editor: " .. mode.mode)
end, debug.traceback)
if rpc then
  pcall(vim.rpcnotify, rpc, "nvim_command", "qa!")
end
vim.wait(300)
pcall(vim.fn.jobstop, chan)
vim.fn.delete(root, "rf")
assert(ok, err)
print("tui-terminal-startup-ok")
