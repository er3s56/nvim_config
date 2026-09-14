local ActivityBar = require("config.activity_bar")

assert(vim.fn.executable("rg") == 1, "Search flags test requires ripgrep")

local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local words = vim.fs.joinpath(root, "words.txt")
assert(vim.fn.writefile({ "needle one", "NEEDLE two", "needles three", "plain four" }, words) == 0)
assert(vim.system({ "git", "-C", root, "init", "-q" }):wait().code == 0)

local function wait(ms, condition, message)
  assert(vim.wait(ms, condition), message)
end

local function picker()
  local state = ActivityBar.current()
  local candidate = state and state.content and state.content.kind == "search" and state.content.picker or nil
  return candidate and not candidate.closed and candidate or nil
end

local function rows(count)
  return function()
    local current = picker()
    return current ~= nil and not current:is_active() and current.list:count() == count
  end
end

local function explorer_ready()
  local state = ActivityBar.current()
  return state.content and state.content.kind == "explorer" and ActivityBar._content_root(state.content)
end

local original_cwd = vim.fn.getcwd(0)
local ok, test_error = pcall(function()
  vim.cmd.cd(vim.fn.fnameescape(root))
  ActivityBar.setup()
  local state = ActivityBar.open("explorer", { focus = false })
  wait(3000, explorer_ready, "Explorer did not become ready")
  local tab = state.tab

  -- Whether the switch at `index` is drawn lit in the Search winbar.
  local function lit(index, label)
    local winbar = vim.wo[picker().input.win.win].winbar
    local button = ("%%#SnacksPickerToggle#%%%d@v:lua.ActivityBarSearchFlagClick@ %s "):format(tab * 10 + index, label)
    return winbar:find(button, 1, true) ~= nil
  end

  -- Literal and smart case to begin with: `needle` finds NEEDLE and needles.
  state.search.query = "needle"
  ActivityBar.open("search", { focus = false })
  wait(3000, rows(3), "Search did not find the three needle-ish lines")
  local current = assert(picker())
  assert(current.opts.regex == false, "Search opened in regex mode")
  local winbar = vim.wo[current.input.win.win].winbar
  assert(winbar:find("ActivityBarSearchFlagClick", 1, true), "Search has no switches in its winbar: " .. winbar)
  assert(not lit(1, "Aa") and not lit(2, "ab") and not lit(3, ".*"), "a switch is lit before being turned on")
  -- Buttons only: the regex toggle Snacks binds to Alt+R is replaced by a
  -- mapping that does nothing, so the key neither flips the mode behind the
  -- button nor, unmapped, reads as Esc and a replace.
  for _, mode in ipairs({ "i", "n" }) do
    local mapping = vim.api.nvim_buf_call(current.input.win.buf, function()
      return vim.fn.maparg("<A-r>", mode, false, true)
    end)
    assert(mapping.desc == "Regex is a button in this search", "Alt+R is not a no-op in Search in mode " .. mode)
  end

  -- Match case drops NEEDLE; whole word then drops needles.
  ActivityBar.toggle_search_flag(tab, "case")
  wait(3000, rows(2), "match case did not drop the capitalised line")
  assert(lit(1, "Aa"), "match case is not lit")
  assert(vim.tbl_contains(current.opts.args, "-s"), "match case did not reach rg")
  ActivityBar.toggle_search_flag(tab, "word")
  wait(3000, rows(1), "whole word did not drop the plural")
  assert(lit(2, "ab") and vim.tbl_contains(current.opts.args, "-w"), "whole word did not reach rg")
  ActivityBar.toggle_search_flag(tab, "case")
  wait(3000, rows(2), "whole word without match case did not take NEEDLE back")
  ActivityBar.toggle_search_flag(tab, "word")
  wait(3000, rows(3), "turning whole word off did not restore the matches")
  assert(#current.opts.args == 0, "rg was left with switch arguments after both went off")

  -- An alternation is a literal until the regex switch says otherwise.
  current.input:set(nil, "needle|plain")
  current:find()
  wait(3000, rows(0), "an alternation matched as a literal")
  ActivityBar.toggle_search_flag(tab, "regex")
  wait(3000, rows(4), "the regex switch did not match the alternation")
  assert(lit(3, ".*") and current.opts.regex == true, "regex is not on")

  -- The switches survive the sidebar showing something else.
  ActivityBar.open("explorer", { focus = false })
  wait(3000, explorer_ready, "Explorer did not replace Search")
  ActivityBar.open("search", { focus = false })
  wait(3000, rows(4), "returning to Search lost the regex results")
  current = assert(picker())
  assert(current.opts.regex == true and lit(3, ".*"), "returning to Search lost the regex switch")
  assert(current.input.filter.search == "needle|plain", "returning to Search lost the query")

  -- A click on a button flips it.
  _G.ActivityBarSearchFlagClick(tab * 10 + 3, 1, "l")
  wait(3000, rows(0), "clicking the regex button did not turn it off")
  assert(state.search.regex == false and not lit(3, ".*"), "the click was not remembered")
end)

vim.cmd.cd(vim.fn.fnameescape(original_cwd))
if not ok then
  io.stderr:write("FAIL: " .. tostring(test_error) .. "\n")
  os.exit(1)
end
print("activity_bar_search_flags: all checks passed")
os.exit(0)
