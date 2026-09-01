-- `:checkhealth config` has to keep telling the truth as these modules change,
-- so each section is exercised both with the UI running and with a fault
-- injected: a report that cannot go red is not a diagnostic.
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")

local function git(...)
  local result = vim.system({ "git", "-C", root, ... }, { text = true }):wait()
  assert(result.code == 0, "git " .. table.concat({ ... }, " ") .. ": " .. (result.stderr or ""))
  return result.stdout
end

git("init", "-q", ".")
vim.fn.writefile({ "hello" }, root .. "/a.txt")
git("add", "-A")
git("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "first")
vim.fn.writefile({ "changed" }, root .. "/a.txt")

-- Run the check and hand back its rendered report. checkhealth opens its own
-- tab page, so close it again rather than leaving it over the UI under test.
local function report()
  local before = vim.api.nvim_get_current_tabpage()
  vim.cmd("checkhealth config")
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local tab = vim.api.nvim_get_current_tabpage()
  if tab ~= before then
    vim.cmd("tabclose")
  end
  return table.concat(lines, "\n")
end

local function has(text, needle, message)
  assert(text:find(needle, 1, true), message .. "\n--- report ---\n" .. text)
end

local function lacks(text, needle, message)
  assert(not text:find(needle, 1, true), message .. "\n--- report ---\n" .. text)
end

vim.cmd.tcd(root)
vim.cmd.edit(root .. "/a.txt")
require("config.file_reload").setup()
local ActivityBar = require("config.activity_bar")
local GitPanel = require("config.git_panel")
local Scrollbar = require("config.picker_scrollbar")
local Finder = require("config.picker_finder")

-- A check that errors out is worse than no check: it hides everything after
-- the point it died. Every section has to render before anything is open.
local empty = report()
for _, section in ipairs({
  "Patches into snacks.nvim",
  "Activity Bar",
  "Git panel",
  "File watchers",
  "Scrollbars",
  "Terminals",
  "Clipboard",
}) do
  has(empty, section, "the report is missing the " .. section .. " section")
end
has(empty, "picker_finder: superseded finder runs are dropped", "the finder patch was not reported as applied")
has(empty, "all patched snacks.nvim functions still exist", "the upstream function check did not run")

ActivityBar.open("explorer", { focus = false })
vim.wait(2000)
ActivityBar.open("git", { focus = false })
assert(
  vim.wait(10000, function()
    local state = GitPanel.current()
    return state ~= nil and state.changes ~= nil and #state.commits > 0
  end),
  "the Git panel never loaded"
)
vim.wait(1000)

local live = report()
has(live, "view=git", "the report did not name the open view")
has(live, "1 change row(s), 1 commit(s)", "the report did not reflect the repository state")
has(live, ".git watcher(s) running", "the running Git watcher was not reported")
has(live, "every registered watch is running", "the file watchers were not reported healthy")
has(live, "directory watch(es) open process-wide", "the watch total was not reported")
lacks(live, "state whose activity column window is gone", "a healthy sidebar was reported as broken")
lacks(live, "left a placeholder window", "a healthy sidebar was reported as mid-switch")

-- Each fault below is one this configuration has actually produced. The check
-- earns its place only by going red for them.
local finder_patched = Finder._patched
Finder._patched = function()
  return false
end
has(report(), "picker_finder: patch not applied", "an unapplied finder patch was not reported")
Finder._patched = finder_patched

local dead_tab = 4242
assert(not vim.api.nvim_tabpage_is_valid(dead_tab), "the fake tab page id is in use")
-- Shaped like a real state: the module's own autocommands walk this table and
-- index its fields unconditionally, as they may, since it only ever holds
-- states the module built itself.
ActivityBar._states[dead_tab] = { view = "explorer", activity = { win = -1, buf = -1 }, generation = 0 }
has(report(), "belong to closed tab pages", "a state left by a closed tab page was not reported")
ActivityBar._states[dead_tab] = nil

local state = assert(GitPanel.current(), "the Git panel closed")
local held = state.git_watcher
state.git_watcher = nil
has(report(), "the .git watcher is not running", "a stopped Git watcher was not reported")
state.git_watcher = held

Scrollbar._bars[9999] = { win = 9998 }
has(report(), "point at a window that is gone", "an orphaned scrollbar was not reported")
Scrollbar._bars[9999] = nil

-- Faults cleared, the report has to go green again: a check that stays red
-- once tripped would be just as useless as one that never fires.
local restored = report()
lacks(restored, "patch not applied", "the finder patch stayed reported as broken")
lacks(restored, "belong to closed tab pages", "the stale tab page state stayed reported")
lacks(restored, "the .git watcher is not running", "the Git watcher stayed reported as stopped")
lacks(restored, "point at a window that is gone", "the orphaned scrollbar stayed reported")

vim.fn.delete(root, "rf")
print("health-ok")
