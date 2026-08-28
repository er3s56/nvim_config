local ActivityBar = require("config.activity_bar")
local TerminalTabs = require("config.terminal_tabs")

local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/src", "p")
assert(vim.fn.writefile({ "x" }, root .. "/src/a.txt") == 0)

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

local original_cwd = vim.fn.getcwd(0)
local original_columns = vim.o.columns
local original_equalalways = vim.o.equalalways
local original_redraw = vim.api.nvim__redraw

local function terminal_win()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.bo[vim.api.nvim_win_get_buf(win)].buftype == "terminal" then
      return win
    end
  end
end

local function open(view)
  local state = ActivityBar.open(view, { focus = false })
  assert(
    vim.wait(5000, function()
      return state.content and state.content.kind == view and ActivityBar._content_root(state.content)
    end),
    ("the %s view did not become ready"):format(view)
  )
  return state
end

local ok, test_error = pcall(function()
  vim.cmd.cd(vim.fn.fnameescape(root))
  vim.cmd.edit(vim.fn.fnameescape(root .. "/src/a.txt"))
  vim.o.columns = 160
  ActivityBar.setup()

  open("explorer")
  TerminalTabs.open(root, false)
  assert(
    vim.wait(5000, function()
      local group = TerminalTabs._groups[TerminalTabs._normalize_root(root)]
      return group and group.active and group.active.terminal:win_valid()
    end),
    "the project terminal did not become ready"
  )
  ActivityBar.reflow()
  vim.wait(200)

  local term = assert(terminal_win(), "no terminal window")
  local width0 = vim.api.nvim_win_get_width(term)
  local editor0 = vim.api.nvim_win_get_position(assert(ActivityBar.editor_window()))[2]

  -- Sample between event-loop ticks with a libuv timer. Intra-tick churn is
  -- invisible (nothing redraws inside a tick); what the user saw flash -- and
  -- what rewrapped the terminal's rendered content -- were the ticks that
  -- *ended* with the sidebar gone and the terminal wider. A WinResized-based
  -- sampler cannot be used here: it depends on redraws, which headless Neovim
  -- does not perform.
  local observed = {}
  local blank_slot_ticks = 0
  local sampler = vim.uv.new_timer()
  sampler:start(
    0,
    3,
    vim.schedule_wrap(function()
      local win = terminal_win()
      if win then
        observed[vim.api.nvim_win_get_width(win)] = true
      end
      -- The sidebar slot (the column right of the Activity Bar) must never
      -- spend a tick holding only the bare placeholder: the old windows are
      -- closed and the new ones opened inside a single tick, so a sampled
      -- blank slot means the swap was torn back into visible pieces.
      local slot_has_content = false
      for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.api.nvim_win_get_config(w).relative == "" then
          local col = vim.api.nvim_win_get_position(w)[2]
          if col > 0 and col < 10 and vim.api.nvim_win_get_width(w) > 5 then
            local ft = vim.bo[vim.api.nvim_win_get_buf(w)].filetype
            if ft ~= "" then
              slot_has_content = true
            end
          end
        end
      end
      if not slot_has_content then
        blank_slot_ticks = blank_slot_ticks + 1
      end
    end)
  )

  for _, view in ipairs({ "git", "search", "explorer", "git" }) do
    open(view)
    vim.wait(600)
  end
  vim.wait(300)
  sampler:stop()
  sampler:close()
  assert(
    blank_slot_ticks == 0,
    ("the sidebar slot was blank for %d sampled ticks during switches"):format(blank_slot_ticks)
  )

  local widths = vim.tbl_keys(observed)
  table.sort(widths)
  assert(
    #widths <= 1 and (widths[1] == nil or widths[1] == width0),
    ("switching views let the terminal settle at widths {%s}; it must stay at %d"):format(
      table.concat(widths, ","),
      width0
    )
  )
  assert(
    vim.api.nvim_win_get_position(assert(ActivityBar.editor_window()))[2] == editor0,
    "the editor column moved across view switches"
  )

  -- The transition machinery must clean up after itself.
  local state = assert(ActivityBar.current())
  assert(state.slot_hold == nil, "a slot placeholder outlived its transition")
  assert(vim.o.equalalways == original_equalalways, "'equalalways' was not restored")
  assert(vim.api.nvim__redraw == original_redraw, "the redraw-flush guard was not removed after the transition")
  local plain = 0
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(win).relative == "" and vim.api.nvim_win_get_width(win) <= 2 then
      plain = plain + (win == state.activity.win and 0 or 1)
    end
  end
  assert(plain == 0, "a leftover one-column placeholder window is still in the layout")

  -- Overlapping switches: each next one starts while the previous is still
  -- in flight, so it must inherit the previous transition's slot hold. When
  -- that inheritance was missing, the unprotected transition let transient
  -- layouts survive across ticks, the terminal's pty was resized to their
  -- widths, and the shell's rendered content was truncated for good.
  local term_buf = vim.api.nvim_win_get_buf(term)
  local function first_terminal_line()
    for _, line in ipairs(vim.api.nvim_buf_get_lines(term_buf, 0, 8, false)) do
      if line ~= "" then
        return line
      end
    end
    return ""
  end
  assert(
    vim.wait(10000, function()
      return first_terminal_line() ~= ""
    end),
    "the terminal never produced a prompt"
  )
  local prompt = first_terminal_line()
  observed = {}
  local stress_sampler = vim.uv.new_timer()
  stress_sampler:start(
    0,
    3,
    vim.schedule_wrap(function()
      local win = terminal_win()
      if win then
        observed[vim.api.nvim_win_get_width(win)] = true
      end
    end)
  )
  -- 30ms spacing lands each open inside the previous transition's async
  -- close window, forcing genuine overlap.
  for _, view in ipairs({ "search", "git", "explorer", "search", "explorer" }) do
    ActivityBar.open(view, { focus = false })
    vim.wait(30)
  end
  assert(
    vim.wait(8000, function()
      local current = ActivityBar.current()
      return current.view == "explorer"
        and current.content
        and current.content.kind == "explorer"
        and ActivityBar._content_root(current.content) ~= nil
        and current.slot_hold == nil
    end),
    "overlapping view switches did not settle cleanly"
  )
  vim.wait(400)
  stress_sampler:stop()
  stress_sampler:close()
  local stress_widths = vim.tbl_keys(observed)
  table.sort(stress_widths)
  assert(
    #stress_widths <= 1 and (stress_widths[1] == nil or stress_widths[1] == width0),
    ("overlapping switches let the terminal settle at widths {%s}"):format(table.concat(stress_widths, ","))
  )
  assert(
    first_terminal_line() == prompt,
    ("overlapping switches corrupted the terminal (was %q, now %q)"):format(prompt, first_terminal_line())
  )
  assert(vim.o.equalalways == original_equalalways, "'equalalways' leaked from a superseded transition")
end)

pcall(ActivityBar.close)
pcall(TerminalTabs.close_all, root)
vim.o.columns = original_columns
vim.o.equalalways = original_equalalways
vim.cmd.cd(vim.fn.fnameescape(original_cwd))
vim.fn.delete(root, "rf")
assert(ok, test_error)

print("activity-bar-switch-stability-ok")
