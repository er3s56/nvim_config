-- Report what this configuration's own UI modules are doing, to `:checkhealth config`.
--
-- Neovim loads `lua/config/*` as plain modules, not as extensions: nothing
-- collects their errors, tracks their resources or notices when one of them
-- quietly stops working. That last case is the dangerous one, because several
-- of these modules only work by patching snacks.nvim internals -- if a release
-- renames `Finder.run`, `picker_finder` returns without patching anything and
-- the duplicate-entry bug comes back with no visible signal at all.
--
-- The modules already expose their state for the test suite. This turns those
-- same tables into a report a person can read, and adds the cross-checks that
-- catch what no single module can see on its own: handles nobody owns any
-- more, windows pointing at windows that are gone, buffers no watcher covers.
local M = {}

-- `package.loaded` rather than `require`: a health check should report that a
-- module never loaded, not load it and hide the fact.
local function module(name)
  return package.loaded["config." .. name]
end

local function count(tbl)
  local total = 0
  for _ in pairs(tbl or {}) do
    total = total + 1
  end
  return total
end

local function win_valid(win)
  return type(win) == "number" and vim.api.nvim_win_is_valid(win)
end

local function buf_valid(buf)
  return type(buf) == "number" and vim.api.nvim_buf_is_valid(buf)
end

-- Every live libuv handle of one type, including any this configuration has
-- lost its reference to. `vim.uv.walk` sees the event loop itself, so it is the
-- only way to tell "we stopped watching" from "we leaked the watch".
local function live_handles(kind)
  local total = 0
  if not vim.uv.walk then
    return nil
  end
  vim.uv.walk(function(handle)
    if handle and not handle:is_closing() and handle:get_type() == kind then
      total = total + 1
    end
  end)
  return total
end

local function check_patches()
  vim.health.start("Patches into snacks.nvim")

  local finder = module("picker_finder")
  if not finder then
    vim.health.warn("config.picker_finder never loaded", {
      "Explorer entries can appear twice. It is loaded from lua/plugins/lazygit.lua.",
    })
  elseif finder._patched() then
    vim.health.ok("picker_finder: superseded finder runs are dropped")
  else
    vim.health.error("picker_finder: patch not applied", {
      "snacks.picker.core.finder.run was missing or not a function.",
      "Explorer entries will appear twice after a quick refresh.",
    })
  end

  local scrollbar = module("picker_scrollbar")
  if not scrollbar then
    vim.health.warn("config.picker_scrollbar never loaded", {
      "The picker lists and the terminal will have no scrollbar.",
    })
  elseif scrollbar._patched() then
    vim.health.ok("picker_scrollbar: list renders are hooked")
  else
    vim.health.error("picker_scrollbar: patch not applied", {
      "snacks.picker.core.list.render was missing or not a function.",
    })
  end

  -- The patches above bail out silently when an upstream name moves, so name
  -- the functions they depend on explicitly: this is what breaks on an update.
  local upstream = {
    { "snacks.picker.core.finder", "run" },
    { "snacks.picker.core.picker", "set_layout" },
    { "snacks.picker.core.list", "render" },
  }
  local missing = {}
  for _, entry in ipairs(upstream) do
    local ok, mod = pcall(require, entry[1])
    if not ok or type(mod) ~= "table" or type(mod[entry[2]]) ~= "function" then
      missing[#missing + 1] = ("%s.%s"):format(entry[1], entry[2])
    end
  end
  if #missing == 0 then
    vim.health.ok("all patched snacks.nvim functions still exist")
  else
    vim.health.error("snacks.nvim moved: " .. table.concat(missing, ", "), {
      "Update lua/config/picker_finder.lua and lua/config/picker_scrollbar.lua.",
    })
  end
end

local function check_activity_bar()
  vim.health.start("Activity Bar")

  local bar = module("activity_bar")
  if not bar then
    return vim.health.warn("config.activity_bar never loaded")
  end

  local states = bar._states or {}
  if count(states) == 0 then
    return vim.health.info("no tab page has the sidebar open")
  end

  local stale = 0
  for tab, state in pairs(states) do
    if not vim.api.nvim_tabpage_is_valid(tab) then
      stale = stale + 1
    else
      local activity = state.activity or {}
      local width = win_valid(activity.win) and vim.api.nvim_win_get_width(activity.win) or nil
      vim.health.info(
        ("tab %d: view=%s%s  sidebar=%d  activity column=%s%s"):format(
          tab,
          state.view or "?",
          state.collapsed and " (collapsed)" or "",
          state.sidebar_width or -1,
          width and (width .. " cols") or "gone",
          state.terminal_height and ("  terminal=" .. state.terminal_height) or ""
        )
      )
      if not win_valid(activity.win) then
        vim.health.error(("tab %d keeps a state whose activity column window is gone"):format(tab))
      end
      -- A held slot is a one-column placeholder that exists only while a view
      -- is being swapped. One still standing means a switch was interrupted.
      if state.slot_hold then
        vim.health.error(("tab %d left a placeholder window from a view switch"):format(tab), {
          "The sidebar will not resize correctly. Reopen the sidebar to clear it.",
        })
      end
    end
  end
  if stale > 0 then
    vim.health.error(("%d state(s) belong to closed tab pages"):format(stale))
  else
    vim.health.ok("no state left behind by a closed tab page")
  end

  local offsets = (require("bufferline.config").options or {}).offsets or {}
  local registered = false
  for _, offset in ipairs(offsets) do
    registered = registered or offset.filetype == "activity_bar"
  end
  if registered then
    vim.health.ok("bufferline reserves the left column")
  else
    vim.health.warn("bufferline has no activity_bar offset", {
      "Buffer tabs will be drawn above the sidebar instead of only above the editor.",
    })
  end
end

local function check_git_panel()
  vim.health.start("Git panel")

  local panel = module("git_panel")
  if not panel then
    return vim.health.warn("config.git_panel never loaded")
  end

  local states = panel._states or {}
  local watching = 0
  if count(states) == 0 then
    vim.health.info("no Git panel open")
  end
  for buf, state in pairs(states) do
    if not buf_valid(buf) then
      vim.health.error(("a state is keyed by buffer %s, which no longer exists"):format(buf))
    else
      vim.health.info(
        ("%s: %d change(s), %d commit(s)%s%s"):format(
          vim.fn.fnamemodify(state.root or "?", ":~"),
          #(state.changes or {}),
          #(state.commits or {}),
          state.commits_exhausted and " (whole history)" or " (more to load)",
          state.commit_loading and ", loading" or ""
        )
      )
    end
    if state.git_watcher and not state.git_watcher:is_closing() then
      watching = watching + 1
    elseif buf_valid(buf) then
      vim.health.error(("%s: the .git watcher is not running"):format(state.root or "?"), {
        "Commits made in a terminal or lazygit will not refresh the panel.",
      })
    end
  end
  if watching > 0 then
    vim.health.ok(("%d .git watcher(s) running"):format(watching))
  end

  -- A row reveals its actions under the pointer only while Neovim asks the
  -- terminal to report movement. Without it the panel still works, from the
  -- cursor row and the right-click menu, but the buttons stop following the
  -- mouse -- which looks like they are gone.
  if count(states) > 0 then
    if vim.o.mousemoveevent then
      vim.health.ok("pointer tracking is on: row actions follow the mouse")
    else
      vim.health.warn("'mousemoveevent' is off: row actions only follow the cursor", {
        "The panel turns it on while it is open, so something else turned it back off.",
      })
    end
  end

  local depths = panel._commit_depths or {}
  if count(depths) > 0 then
    local parts = {}
    for root, depth in pairs(depths) do
      parts[#parts + 1] = ("%s=%d%s"):format(
        vim.fn.fnamemodify(root, ":t"),
        depth.offset or 0,
        depth.exhausted and " (end)" or ""
      )
    end
    vim.health.info("expanded history remembered for: " .. table.concat(parts, ", "))
  end
end

local function check_watchers()
  vim.health.start("File watchers")

  local reload = module("file_reload")
  if not reload then
    return vim.health.warn("config.file_reload never loaded", {
      "Files changed outside Neovim will not be reloaded until the window regains focus.",
    })
  end

  local watchers = reload._watchers or {}
  local owned, dead = 0, 0
  for dir, entry in pairs(watchers) do
    if entry.handle and not entry.handle:is_closing() then
      owned = owned + 1
    else
      dead = dead + 1
      vim.health.error(("the watch on %s is dead"):format(vim.fn.fnamemodify(dir, ":~")))
    end
  end
  vim.health.info(("watching %d directory/directories, %d check(s) run"):format(owned, reload._checks()))
  if dead == 0 then
    vim.health.ok("every registered watch is running")
  end

  -- A loaded file with no watch is a file that will silently go stale.
  local uncovered = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local dir = reload._buffer_dir(buf)
    if dir and not watchers[dir] then
      uncovered[#uncovered + 1] = vim.fn.fnamemodify(dir, ":~")
    end
  end
  if #uncovered == 0 then
    vim.health.ok("every loaded file's directory is watched")
  else
    vim.health.warn(("%d director(ies) hold a loaded file but are not watched"):format(#uncovered), {
      "First: " .. uncovered[1],
      "Changes made there by another program will not be picked up.",
    })
  end

  -- Directory watches are a limited kernel resource, so it is worth seeing how
  -- many are open. Only the total is knowable here: gitsigns and the snacks
  -- Explorer keep their own, and there is no way to ask a handle who opened it.
  -- Whether *our* watches outlive their panels is asserted in
  -- tests/git_panel_refresh.lua, which can follow individual handles.
  local live = live_handles("fs_event")
  if live then
    local git = module("git_panel")
    local git_watchers = 0
    for _, state in pairs(git and git._states or {}) do
      if state.git_watcher and not state.git_watcher:is_closing() then
        git_watchers = git_watchers + 1
      end
    end
    vim.health.info(
      ("%d directory watch(es) open process-wide; %d are ours (%d file reload, %d Git), the rest belong to other plugins"):format(
        live,
        owned + git_watchers,
        owned,
        git_watchers
      )
    )
  end
end

local function check_scrollbars()
  vim.health.start("Scrollbars")

  local scrollbar = module("picker_scrollbar")
  if not scrollbar then
    return vim.health.warn("config.picker_scrollbar never loaded")
  end

  local bars = scrollbar._bars or {}
  local orphans = 0
  for target, bar in pairs(bars) do
    if not win_valid(target) or not win_valid(bar.win) then
      orphans = orphans + 1
    end
  end
  vim.health.info(("%d scrollbar(s) drawn"):format(count(bars)))
  if orphans == 0 then
    vim.health.ok("every scrollbar still has a window to sit beside")
  else
    vim.health.error(("%d scrollbar(s) point at a window that is gone"):format(orphans), {
      "A floating window may be left over the editor. Reopen the sidebar to clear it.",
    })
  end
end

local function check_terminals()
  vim.health.start("Terminals")

  local terminals = module("terminal_tabs")
  if not terminals then
    return vim.health.warn("config.terminal_tabs never loaded")
  end

  local groups = terminals._groups or {}
  if count(groups) == 0 then
    return vim.health.info("no terminal open")
  end
  local dead = 0
  for root, group in pairs(groups) do
    for _, item in ipairs(group.items or {}) do
      local buf = item.terminal and item.terminal.buf
      if buf and not buf_valid(buf) then
        dead = dead + 1
      end
    end
    vim.health.info(
      ("%s: %d terminal(s)%s"):format(
        vim.fn.fnamemodify(root, ":~"),
        #(group.items or {}),
        group.visible and ", visible" or ", hidden"
      )
    )
  end
  if dead == 0 then
    vim.health.ok("every listed terminal still has its buffer")
  else
    vim.health.error(("%d terminal(s) list a buffer that is gone"):format(dead))
  end
end

local function check_clipboard()
  vim.health.start("Clipboard")

  -- `g:clipboard` is a manual override; otherwise Neovim probes for a tool and
  -- caches the answer in `g:loaded_clipboard_provider`.
  local provider = vim.g.clipboard and "g:clipboard"
    or vim.fn.exists("g:loaded_clipboard_provider") == 1 and "auto"
    or nil
  local usable = vim.fn.has("clipboard") == 1
  if usable then
    vim.health.ok(("system clipboard available (%s)"):format(provider or "builtin"))
  else
    vim.health.error("no clipboard tool found", {
      'Yanking to "+ and pasting from the system clipboard will not work.',
      "In WSL, install win32yank; it does not interfere with terminal image paste.",
    })
  end
end

function M.check()
  check_patches()
  check_activity_bar()
  check_git_panel()
  check_watchers()
  check_scrollbars()
  check_terminals()
  check_clipboard()
end

return M
