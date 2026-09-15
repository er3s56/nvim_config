-- Runs the tests in this directory, each in a Neovim of its own with the real
-- configuration loaded, and says which passed.
--
--   nvim -l tests/run.lua                  every test
--   nvim -l tests/run.lua git_panel hunks   those whose name has any of these
--   nvim -l tests/run.lua --list            the names, and nothing run
--   nvim -l tests/run.lua -j 4              four at a time
--   nvim -l tests/run.lua --timeout 60      give each up after a minute
--
-- A test is a script that exits 0 when it passes. It runs as
-- `nvim -u init.lua -l tests/<name>.lua` from the configuration root, which
-- is what each of them expects. The exit status is 0 when nothing failed
-- that was not expected to.
local uv = vim.uv

local here = vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2)))
local root = vim.fs.dirname(here)

-- Tests that fail for a reason outside this configuration. They still run:
-- one that passes has outgrown its entry, and is reported so.
--
-- The grid abort is nvim 0.12-dev tripping an assertion of its own while
-- redrawing headless; these six failed the same way on the configuration as
-- it was before any of them was touched (checked against 9ed9095).
local GRID_ABORT = "nvim 0.12-dev aborts on grid.c:595 grid_line_flush assertion"
local KNOWN = {
  activity_bar_regressions = GRID_ABORT,
  activity_bar_switch_stability = GRID_ABORT,
  context_menu_dismiss = GRID_ABORT,
  git_panel_preview_teardown = GRID_ABORT,
  picker_scrollbar = GRID_ABORT,
  terminal_selection = GRID_ABORT,
}

local filters, list, jobs, timeout_ms = {}, false, 1, 120000
do
  local args = _G.arg or {}
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "--list" then
      list = true
    elseif a == "-j" or a == "--jobs" then
      jobs, i = tonumber(args[i + 1]) or jobs, i + 1
    elseif a:match("^%-j%d+$") then
      jobs = tonumber(a:sub(3))
    elseif a == "--timeout" then
      timeout_ms, i = (tonumber(args[i + 1]) or 120) * 1000, i + 1
    elseif a:sub(1, 1) == "-" then
      io.stderr:write("unknown option " .. a .. "\n")
      os.exit(2)
    else
      filters[#filters + 1] = a
    end
    i = i + 1
  end
  jobs = math.max(1, math.floor(jobs))
end

local names = {}
for name, kind in vim.fs.dir(here) do
  local base = name:match("^(.+)%.lua$")
  if kind == "file" and base and base ~= "run" then
    names[#names + 1] = base
  end
end
table.sort(names)
if #filters > 0 then
  names = vim.tbl_filter(function(name)
    for _, filter in ipairs(filters) do
      if name:find(filter, 1, true) then
        return true
      end
    end
    return false
  end, names)
end

if list then
  for _, name in ipairs(names) do
    io.write(name, KNOWN[name] and "  (known failure)" or "", "\n")
  end
  os.exit(0)
end
if #names == 0 then
  io.stderr:write("no test matches " .. table.concat(filters, " ") .. "\n")
  os.exit(2)
end

local tty = uv.guess_handle(1) == "tty"
local function paint(code, text)
  return tty and ("\27[%sm%s\27[0m"):format(code, text) or text
end

-- The last `count` lines of `text` that say anything.
local function tail(text, count)
  local lines = {}
  for line in (text or ""):gmatch("[^\n]+") do
    if line:match("%S") then
      lines[#lines + 1] = line
    end
  end
  return vim.list_slice(lines, math.max(#lines - count + 1, 1))
end

local results = {}
local queue = vim.list_extend({}, names)
local running = 0

local function launch(name)
  running = running + 1
  local started = uv.hrtime()
  vim.system(
    { "nvim", "-u", "init.lua", "-l", "tests/" .. name .. ".lua" },
    { cwd = root, text = true, timeout = timeout_ms },
    function(out)
      results[name] = {
        code = out.code,
        signal = out.signal or 0,
        output = (out.stderr or "") .. "\n" .. (out.stdout or ""),
        seconds = (uv.hrtime() - started) / 1e9,
      }
      running = running - 1
    end
  )
end

local counts = { ok = 0, failed = 0, known = 0, outgrown = 0 }

local function report(name)
  local result = results[name]
  local timed_out = result.code == 124
  local crashed = not timed_out and result.signal ~= 0
  local passed = result.code == 0 and not crashed
  local known = KNOWN[name]
  local status, color, note
  if passed and known then
    status, color, note = "pass?", "33", "passes now; its entry in KNOWN can go"
    counts.outgrown = counts.outgrown + 1
  elseif passed then
    status, color = "ok", "32"
    counts.ok = counts.ok + 1
  elseif known then
    status, color, note = "known", "90", known
    counts.known = counts.known + 1
  else
    status, color = "FAIL", "31"
    counts.failed = counts.failed + 1
    note = timed_out and ("timed out after %ds"):format(timeout_ms / 1000)
      or crashed and ("crashed (signal %d)"):format(result.signal)
      or nil
  end
  io.write(("  %s %-36s %5.1fs\n"):format(paint(color, ("%-5s"):format(status)), name, result.seconds))
  if note then
    io.write("        " .. note .. "\n")
  end
  if status == "FAIL" then
    for _, line in ipairs(tail(result.output, 6)) do
      io.write("        " .. line .. "\n")
    end
  end
  io.flush()
end

local began = uv.hrtime()
local reported = 0
while reported < #names do
  while #queue > 0 and running < jobs do
    launch(table.remove(queue, 1))
  end
  -- Results come back in any order; they are reported in list order, as each
  -- becomes the next one due.
  vim.wait(50, function()
    return results[names[reported + 1]] ~= nil
  end)
  while reported < #names and results[names[reported + 1]] do
    reported = reported + 1
    report(names[reported])
  end
end

local summary = { ("%d ok"):format(counts.ok) }
if counts.failed > 0 then
  summary[#summary + 1] = paint("31", ("%d failed"):format(counts.failed))
end
if counts.known > 0 then
  summary[#summary + 1] = ("%d known"):format(counts.known)
end
if counts.outgrown > 0 then
  summary[#summary + 1] = paint("33", ("%d passing despite KNOWN"):format(counts.outgrown))
end
io.write(("\n%d tests: %s   %.0fs\n"):format(#names, table.concat(summary, ", "), (uv.hrtime() - began) / 1e9))
os.exit(counts.failed == 0 and 0 or 1)
