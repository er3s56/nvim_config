-- Render-level invariants that headless tests cannot see: what the child
-- Neovim actually flushes to its terminal. A child runs the full config
-- inside a :terminal of this (headless) host; the host's terminal buffer is
-- driven by the child's flushed bytes, so sampling it observes real frames
-- without disturbing the child. Only timing-robust invariants are asserted:
-- no frame count or duration checks.
local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/src", "p")
assert(vim.fn.writefile({ "local x = 1" }, root .. "/src/a.lua") == 0)
assert(vim.fn.writefile({ "# readme" }, root .. "/README.md") == 0)
local function git(args)
  local command = { "git", "-C", root }
  vim.list_extend(command, args)
  local result = vim.system(command, { text = true }):wait()
  assert(result.code == 0, result.stderr)
end
git({ "init", "-q" })
git({ "config", "user.name", "t" })
git({ "config", "user.email", "t@example.invalid" })
git({ "add", "-A" })
git({ "commit", "-qm", "init" })

vim.o.columns = 160
vim.o.lines = 45
vim.o.laststatus = 0
vim.o.showtabline = 0
local host_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(0, host_buf)
local sock = vim.fn.tempname() .. ".sock"
local chan = vim.fn.jobstart({ "nvim", "--listen", sock }, {
  term = true,
  cwd = root,
  env = { TERM = "xterm-256color", NVIM = "", NVIM_LISTEN_ADDRESS = "" },
  clear_env = false,
})
assert(chan > 0, "could not start the child Neovim")

local rpc
local bad_frames = {}
local ok, test_error = pcall(function()
  assert(
    vim.wait(30000, function()
      return vim.fn.filereadable(sock) == 1 or vim.fn.getftype(sock) ~= ""
    end, 50),
    "the child Neovim never created its socket"
  )
  local connect_ok
  connect_ok, rpc = pcall(vim.fn.sockconnect, "pipe", sock, { rpc = true })
  assert(connect_ok and rpc > 0, "could not connect to the child Neovim")
  local function child(chunk)
    local eval_ok, result = pcall(vim.rpcrequest, rpc, "nvim_exec_lua", chunk, {})
    assert(eval_ok, ("child eval failed: %s"):format(tostring(result)))
    return result
  end
  local function click(row)
    vim.fn.chansend(chan, ("\27[<0;2;%dM"):format(row))
    vim.fn.chansend(chan, ("\27[<0;2;%dm"):format(row))
  end

  -- Sample the host's view of the child while waiting: a `╭` in the first
  -- four columns means a sidebar box was flushed left of the Activity Bar,
  -- which is the misplaced-frame flicker.
  local function watch(ms)
    local deadline = vim.uv.hrtime() + ms * 1e6
    while vim.uv.hrtime() < deadline do
      local lines = vim.api.nvim_buf_get_lines(host_buf, 0, 44, false)
      for index, line in ipairs(lines) do
        local head = vim.fn.strcharpart(line, 0, 4)
        if head:find("╭", 1, true) then
          bad_frames[#bad_frames + 1] = ("row %d: %s"):format(index, vim.fn.strcharpart(line, 0, 30))
        end
      end
      vim.wait(2, function()
        return false
      end)
    end
  end

  assert(
    vim.wait(30000, function()
      local ready = pcall(vim.rpcrequest, rpc, "nvim_exec_lua", "return _G.Snacks ~= nil", {})
      if not ready then
        return false
      end
      return child([[
        local ok, ab = pcall(require, "config.activity_bar")
        if not ok then return false end
        local st = ab.current()
        return st ~= nil and ab._content_root(st.content) ~= nil
      ]])
    end, 200),
    "the child's panels never became ready"
  )
  watch(2000)

  local prompt = child([[
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local b = vim.api.nvim_win_get_buf(w)
      if vim.bo[b].buftype == "terminal" then
        for _, l in ipairs(vim.api.nvim_buf_get_lines(b, 0, 8, false)) do
          if l ~= "" then return l end
        end
      end
    end
    return ""
  ]])
  assert(prompt ~= "", "the child's project terminal never produced a prompt")

  -- Ordinary switches, collapse, expand, then a rapid burst.
  for _, row in ipairs({ 4, 2, 3, 3, 3 }) do
    click(row)
    watch(1200)
  end
  for _, row in ipairs({ 4, 2, 3, 4, 2, 3, 4, 2 }) do
    click(row)
    watch(500)
  end
  watch(3000)

  assert(
    #bad_frames == 0,
    ("a sidebar frame was flushed left of the Activity Bar:\n%s"):format(table.concat(bad_frames, "\n"))
  )

  local prompt_after = child([[
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local b = vim.api.nvim_win_get_buf(w)
      if vim.bo[b].buftype == "terminal" then
        for _, l in ipairs(vim.api.nvim_buf_get_lines(b, 0, 8, false)) do
          if l ~= "" then return l end
        end
      end
    end
    return ""
  ]])
  assert(
    prompt_after == prompt,
    ("switching corrupted the terminal content (was %q, now %q)"):format(prompt, prompt_after)
  )

  local stray_bars = child([[
    local out = {}
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      local cfg_ok, cfg = pcall(vim.api.nvim_win_get_config, w)
      if cfg_ok and cfg.relative ~= "" then
        local b = vim.api.nvim_win_get_buf(w)
        if vim.bo[b].filetype == "scrollview" and (tonumber(cfg.col) or 999) < 100 then
          out[#out + 1] = ("col=%s"):format(tostring(cfg.col))
        end
      end
    end
    return table.concat(out, " ")
  ]])
  assert(
    stray_bars == "",
    ("a scrollview bar is back inside the sidebar region (%s); its deferred refresh flickers on every switch"):format(
      stray_bars
    )
  )
end)

if rpc then
  pcall(vim.fn.chanclose, rpc)
end
pcall(vim.fn.jobstop, chan)
vim.fn.delete(root, "rf")
assert(ok, test_error)

print("tui-render-ok")
