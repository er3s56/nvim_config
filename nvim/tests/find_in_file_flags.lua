local ActivityBar = require("config.activity_bar")
local FindInFile = require("config.find_in_file")

local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local a = vim.fs.joinpath(root, "a.txt")
local b = vim.fs.joinpath(root, "b.txt")
assert(vim.fn.writefile({ "first needle", "plain line", "NEEDLE shouting", "needles plural" }, a) == 0)
assert(vim.fn.writefile({ "other" }, b) == 0)

local function wait(ms, condition, message)
  assert(vim.wait(ms, condition), message)
end

local function picker()
  local strip = FindInFile._strips[vim.api.nvim_get_current_tabpage()]
  local candidate = strip and strip.picker
  return candidate and not candidate.closed and candidate or nil
end

local function rows(count)
  return function()
    local current = picker()
    return current ~= nil and current.shown == true and not current:is_active() and current.list:count() == count
  end
end

-- Whether the switch at `index` is drawn lit in the winbar of the strip.
local function lit(index, label)
  local winbar = vim.wo[picker().input.win.win].winbar
  local button = ("%%#SnacksPickerToggle#%%%d@v:lua.FindInFileFlagClick@ %s "):format(index, label)
  return winbar:find(button, 1, true) ~= nil
end

local original_cwd = vim.fn.getcwd(0)
local ok, test_error = pcall(function()
  vim.cmd.cd(vim.fn.fnameescape(root))
  ActivityBar.setup()
  FindInFile.setup()
  local state = ActivityBar.open("explorer", { focus = false })
  wait(3000, function()
    return state.content and state.content.kind == "explorer" and ActivityBar._content_root(state.content)
  end, "Explorer did not become ready")
  local editor = assert(ActivityBar.editor_window())
  vim.api.nvim_set_current_win(editor)
  vim.cmd.edit(vim.fn.fnameescape(a))

  -- Smart case and fuzzy to begin with: `needle` finds NEEDLE and needles.
  FindInFile.open("needle")
  wait(3000, rows(3), "the strip did not find the three needle-ish lines")
  local winbar = vim.wo[picker().input.win.win].winbar
  assert(winbar:find("FindInFileFlagClick", 1, true), "the strip has no switches in its winbar: " .. winbar)
  assert(not lit(1, "Aa") and not lit(2, "ab") and not lit(3, ".*"), "a switch is lit before being turned on")
  -- Buttons only: the regex toggle Snacks binds to Alt+R is replaced by a
  -- mapping that does nothing, so the key neither flips the mode behind the
  -- button nor, unmapped, reads as Esc and a replace.
  for _, mode in ipairs({ "i", "n" }) do
    local mapping = vim.api.nvim_buf_call(picker().input.win.buf, function()
      return vim.fn.maparg("<A-r>", mode, false, true)
    end)
    assert(mapping.desc == "Regex is a button in this search", "Alt+R is not a no-op in the strip in mode " .. mode)
  end

  -- Match case drops NEEDLE; whole word then drops needles.
  FindInFile.toggle("case")
  wait(3000, rows(2), "match case did not drop the capitalised line")
  assert(lit(1, "Aa"), "match case is not lit")
  FindInFile.toggle("word")
  wait(3000, rows(1), "whole word did not drop the plural")
  assert(lit(2, "ab"), "whole word is not lit")
  FindInFile.toggle("case")
  wait(3000, rows(2), "whole word without match case did not take NEEDLE back")
  assert(not lit(1, "Aa"), "match case is still lit")
  FindInFile.toggle("word")
  wait(3000, rows(3), "turning whole word off did not restore the fuzzy matches")

  -- A Vim regex is nothing to the fuzzy matcher, and everything to the
  -- regex switch. Case stays smart under it, and whole word anchors it.
  local current = assert(picker())
  current.input:set("needle\\|plain")
  current:find()
  wait(3000, rows(0), "a regex matched as a fuzzy query")
  FindInFile.toggle("regex")
  wait(3000, rows(4), "the regex switch did not match the alternation")
  assert(lit(3, ".*"), "regex is not lit")
  FindInFile.toggle("case")
  wait(3000, rows(3), "match case under regex did not drop NEEDLE")
  -- One switch at a time, settled in between, as a hand on the keys would:
  -- two in one tick abort a matcher run that has not started, and Snacks
  -- lets such a run finish anyway (see picker_finder.lua).
  FindInFile.toggle("case")
  wait(3000, rows(4), "turning match case off under regex did not take NEEDLE back")
  FindInFile.toggle("word")
  wait(3000, rows(3), "whole word under regex did not drop the plural")

  -- The switches are kept across buffers; the query is not.
  vim.api.nvim_set_current_win(editor)
  vim.cmd.edit(vim.fn.fnameescape(b))
  wait(3000, function()
    return picker() == nil
  end, "switching buffers did not fold the strip")
  FindInFile.open("other")
  wait(3000, rows(1), "the strip did not find the one line of b.txt")
  assert(lit(2, "ab") and lit(3, ".*") and not lit(1, "Aa"), "the switches did not carry over to b.txt")
  assert(FindInFile._flags.word and FindInFile._flags.regex and not FindInFile._flags.case, "flags disagree")

  -- A click on a button flips it.
  _G.FindInFileFlagClick(3, 1, "l")
  wait(3000, function()
    return not FindInFile._flags.regex and not lit(3, ".*")
  end, "clicking the regex button did not turn it off")
  wait(3000, rows(1), "the strip did not settle after the click")
  FindInFile.toggle("word")
  wait(3000, rows(1), "the strip did not settle after the switches went back")
end)

vim.cmd.cd(vim.fn.fnameescape(original_cwd))
if not ok then
  io.stderr:write("FAIL: " .. tostring(test_error) .. "\n")
  os.exit(1)
end
print("find_in_file_flags: all checks passed")
os.exit(0)
