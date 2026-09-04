-- The few places in a project you keep going back to.
--
-- Every project has them: the directory the downloaded images land in, the
-- driver sources three levels down, the log directory nobody remembers the
-- name of. They are not recent -- recency lists lose them the moment you work
-- on something else for an afternoon -- and they are not always inside the
-- project either, so the file tree cannot show them without leaving where it
-- is. Pin them, and they sit at the top of the sidebar until you say otherwise.
--
-- Kept per project, because "the driver directory" means a different path in
-- every project, and written to the state directory rather than into the
-- project, which is not this configuration's to litter.

local ContextMenu = require("config.context_menu")
local WinOptions = require("config.win_options")

local M = {}

local MAX_ROWS = 8
local ns = vim.api.nvim_create_namespace("project_pinned")

local store
local panel
local collapsed = false

local store_override

--- Where the pins are kept. Configurable so a test can point it at a scratch
--- file instead of the state directory it shares with everything else.
function M.setup(opts)
  store_override = opts and opts.file or nil
  store = nil
end

local function store_file()
  return store_override or vim.fs.joinpath(vim.fn.stdpath("data"), "project_pins.json")
end

local function normalize(path)
  if not path or path == "" then
    return nil
  end
  return (vim.fs.normalize(vim.fn.fnamemodify(path, ":p")):gsub("/+$", ""))
end

local function load_store()
  if store then
    return store
  end
  store = {}
  local file = io.open(store_file(), "r")
  if file then
    local text = file:read("*a")
    file:close()
    local ok, decoded = pcall(vim.json.decode, text)
    if ok and type(decoded) == "table" then
      -- Anything that is not a list of strings is not ours; a half-written or
      -- hand-edited file must not stop the sidebar from opening.
      for root, paths in pairs(decoded) do
        if type(root) == "string" and type(paths) == "table" then
          local kept = {}
          for _, path in ipairs(paths) do
            if type(path) == "string" then
              kept[#kept + 1] = path
            end
          end
          store[root] = kept
        end
      end
    end
  end
  return store
end

local function save_store()
  local ok, encoded = pcall(vim.json.encode, store or {})
  if not ok then
    return
  end
  local file = io.open(store_file(), "w")
  if not file then
    return
  end
  file:write(encoded)
  file:close()
end

--- The project a path belongs to, the same way the rest of the sidebar
--- decides it, so a pin made from the tree and one made from a command land
--- under the same key.
function M.project_root()
  if rawget(_G, "LazyVim") and LazyVim.root then
    local ok, root = pcall(LazyVim.root)
    if ok and root then
      return normalize(root)
    end
  end
  return normalize(vim.uv.cwd())
end

--- The pinned paths of a project, in the order they were pinned.
function M.list(root)
  root = normalize(root)
  if not root then
    return {}
  end
  return vim.deepcopy(load_store()[root] or {})
end

function M.is_pinned(root, path)
  root, path = normalize(root), normalize(path)
  if not root or not path then
    return false
  end
  return vim.tbl_contains(load_store()[root] or {}, path)
end

function M.add(root, path)
  root, path = normalize(root), normalize(path)
  if not root or not path or M.is_pinned(root, path) then
    return false
  end
  local paths = load_store()[root] or {}
  paths[#paths + 1] = path
  store[root] = paths
  save_store()
  M.render()
  return true
end

function M.remove(root, path)
  root, path = normalize(root), normalize(path)
  if not root or not path then
    return false
  end
  local paths = load_store()[root]
  if not paths then
    return false
  end
  for index, pinned in ipairs(paths) do
    if pinned == path then
      table.remove(paths, index)
      if #paths == 0 then
        store[root] = nil
      end
      save_store()
      M.render()
      return true
    end
  end
  return false
end

-- ── what a row says ─────────────────────────────────────────────────────

local function is_directory(path)
  local stat = vim.uv.fs_stat(path)
  return stat and stat.type == "directory" or false
end

-- The basename alone, unless two pins share one: a sidebar this narrow has no
-- room for full paths, and "drivers" twice tells the reader nothing.
local function labels(paths)
  local seen, result = {}, {}
  for _, path in ipairs(paths) do
    local name = vim.fs.basename(path)
    seen[name] = (seen[name] or 0) + 1
  end
  for index, path in ipairs(paths) do
    local name = vim.fs.basename(path)
    if seen[name] > 1 then
      local parent = vim.fs.basename(vim.fs.dirname(path))
      name = parent ~= "" and (parent .. "/" .. name) or name
    end
    result[index] = name
  end
  return result
end

-- ── the panel ───────────────────────────────────────────────────────────

local function valid_panel()
  return panel
    and vim.api.nvim_win_is_valid(panel.win)
    and vim.api.nvim_buf_is_valid(panel.buf)
    and vim.api.nvim_win_get_buf(panel.win) == panel.buf
end

local function row_at(line)
  return panel and panel.rows and panel.rows[line] or nil
end

local function inside(path, parent)
  return path == parent or path:sub(1, #parent + 1) == parent .. "/"
end

local function tree_root()
  local picker = panel and panel.picker
  if picker and not picker.closed and picker.cwd then
    local ok, cwd = pcall(picker.cwd, picker)
    if ok then
      return normalize(cwd)
    end
  end
end

function M.render()
  if not valid_panel() then
    return
  end
  local paths = M.list(panel.root)
  local names = labels(paths)
  local lines = { (collapsed and "▸" or "▾") .. " PINNED" }
  local rows = {}
  if not collapsed then
    -- A pin can take the tree somewhere else entirely, and the tree has no way
    -- back to a project it is no longer inside. This row is that way back, and
    -- it is only here while it is needed.
    local cwd = tree_root()
    if cwd and panel.root and cwd ~= panel.root then
      lines[#lines + 1] = ("   󰋜 %s"):format(vim.fs.basename(panel.root))
      rows[#lines] = { path = panel.root, home = true }
    end
    for index, path in ipairs(paths) do
      local directory = is_directory(path)
      lines[#lines + 1] = ("   %s %s"):format(directory and "" or "", names[index])
      rows[#lines] = { path = path, directory = directory }
    end
    if #paths == 0 then
      lines[#lines + 1] = "   nothing pinned yet"
    end
  end
  panel.rows = rows

  vim.bo[panel.buf].modifiable = true
  vim.api.nvim_buf_set_lines(panel.buf, 0, -1, false, lines)
  vim.bo[panel.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(panel.buf, ns, 0, -1)
  vim.api.nvim_buf_set_extmark(panel.buf, ns, 0, 0, { end_col = #lines[1], hl_group = "Title" })
  for line in pairs(rows) do
    vim.api.nvim_buf_set_extmark(panel.buf, ns, line - 1, 0, { end_col = 5, hl_group = "Directory" })
  end
  if #paths == 0 and not collapsed then
    vim.api.nvim_buf_set_extmark(panel.buf, ns, #lines - 1, 0, { end_col = #lines[#lines], hl_group = "Comment" })
  end

  local height = math.max(1, math.min(#lines, MAX_ROWS + 1))
  if vim.api.nvim_win_get_height(panel.win) ~= height then
    WinOptions.set(panel.win, { winfixheight = false })
    pcall(vim.api.nvim_win_set_height, panel.win, height)
    if vim.api.nvim_win_is_valid(panel.win) then
      WinOptions.set(panel.win, { winfixheight = true })
    end
  end
  M.resync()
end

--- The rows this panel takes come out of the file tree below it, and the
--- Picker keeps its own idea of how tall its list is -- refreshed, by its own
--- machinery, on WinResized. Taking rows without saying so leaves it
--- addressing rows that are no longer on screen: measured, the bottom item of
--- a scrolled tree could not be clicked at all.
function M.resync()
  local picker = panel and panel.picker
  local list = picker and not picker.closed and picker.list or nil
  local win = list and list.win and list.win.win
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  -- The same three lines the Picker runs for itself when a window it owns is
  -- resized. Sending it a WinResized of our own is not the way: the real event
  -- carries the list of windows that moved, and handlers elsewhere read it.
  local height = vim.api.nvim_win_get_height(win)
  if height == list.state.height then
    return
  end
  list.state.height = height
  list.dirty = true
  pcall(list.update, list)
end

--- Go to a pinned path. A file opens. A directory inside the tree is opened
--- where it stands; one outside it -- the mirror the downloads land in, a
--- driver tree shared between projects -- becomes the tree's root, because a
--- tree rooted at the project cannot show it at all. Going somewhere else is
--- what the row above puts back.
function M.activate(entry)
  if not entry then
    return
  end
  if entry.home then
    local picker = panel and panel.picker
    if picker and not picker.closed then
      pcall(picker.set_cwd, picker, entry.path)
      pcall(picker.find, picker)
      M.render()
    end
    return
  end
  if entry.directory then
    local cwd = tree_root()
    if cwd and not inside(entry.path, cwd) then
      local picker = panel.picker
      pcall(picker.set_cwd, picker, entry.path)
      pcall(picker.find, picker)
      M.render()
    else
      pcall(Snacks.explorer.reveal, { file = entry.path })
    end
    return
  end
  local ActivityBar = require("config.activity_bar")
  local editor = ActivityBar.editor_window()
  if not editor or not vim.api.nvim_win_is_valid(editor) then
    return
  end
  vim.api.nvim_set_current_win(editor)
  vim.cmd.edit(vim.fn.fnameescape(entry.path))
end

local function activate_line(line)
  if line == 1 then
    collapsed = not collapsed
    M.render()
    return
  end
  M.activate(row_at(line))
end

local function menu_entries(line)
  local entry = row_at(line)
  local root = panel and panel.root
  if not entry then
    return {
      {
        label = collapsed and "Expand" or "Collapse",
        action = function()
          collapsed = not collapsed
          M.render()
        end,
      },
    }
  end
  return {
    { label = "Open", action = function() M.activate(entry) end },
    {
      label = "Reveal in Explorer",
      action = function()
        pcall(Snacks.explorer.reveal, { file = entry.path })
      end,
    },
    {
      label = "Copy Path",
      action = function()
        vim.fn.setreg("+", entry.path)
        vim.notify("Copied " .. entry.path)
      end,
    },
    { separator = true },
    { label = "Unpin", action = function() M.remove(root, entry.path) end },
  }
end

local function map(buf, keys, callback)
  for _, key in ipairs(keys) do
    vim.keymap.set("n", key, callback, { buffer = buf, silent = true, nowait = true })
  end
end

local heal_timer

local function schedule_heal()
  if heal_timer then
    pcall(function()
      heal_timer:stop()
    end)
  end
  heal_timer = vim.defer_fn(function()
    heal_timer = nil
    M.restack()
    M.resync()
  end, 80)
end

--- Put the panel above the file tree. It is part of the Explorer view and
--- lives and dies with it: nothing to restore, nothing to leak.
function M.attach(anchor, root, picker)
  M.detach()
  if not anchor or not vim.api.nvim_win_is_valid(anchor) then
    return
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "project-pinned://" .. tostring(vim.api.nvim_get_current_tabpage()))
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].buflisted = false
  vim.bo[buf].filetype = "project_pinned"

  local ok, win = pcall(vim.api.nvim_open_win, buf, false, {
    split = "above",
    win = anchor,
    height = 1,
  })
  if not ok then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    return
  end
  WinOptions.set(win, {
    number = false,
    relativenumber = false,
    signcolumn = "no",
    statuscolumn = "",
    foldcolumn = "0",
    wrap = false,
    list = false,
    cursorline = true,
    winbar = "",
    winfixheight = true,
    winfixwidth = true,
  })

  panel = { win = win, buf = buf, root = normalize(root), rows = {}, picker = picker }

  map(buf, { "<CR>", "<2-LeftMouse>" }, function()
    activate_line(vim.api.nvim_win_get_cursor(win)[1])
  end)
  -- The press positions the cursor, the release acts on the row it landed on:
  -- one click opens, the way the file tree beside it behaves.
  map(buf, { "<LeftRelease>" }, function()
    vim.schedule(function()
      if valid_panel() then
        activate_line(vim.api.nvim_win_get_cursor(win)[1])
      end
    end)
  end)
  -- The press is swallowed and the menu opens on the release: left to Neovim,
  -- a right click in a window like this one raises its own built-in menu.
  map(buf, { "<RightMouse>" }, function() end)
  map(buf, { "<RightRelease>" }, function()
    local mouse = vim.fn.getmousepos()
    if mouse.winid ~= win then
      return
    end
    local line = math.max(1, mouse.line)
    pcall(vim.api.nvim_win_set_cursor, win, { math.min(line, vim.api.nvim_buf_line_count(buf)), 0 })
    ContextMenu.open(menu_entries(line), mouse, { filetype = "pinned_context_menu" })
  end)

  -- The sidebar is rearranged by several hands -- a panel swap, a reflow, the
  -- Picker closing and rebuilding its own windows when the terminal is resized
  -- -- and none of them know this window is part of the column. Check after
  -- each, and only once the rearranging has stopped: measured, a check run
  -- during it restacks against a window that is itself about to be replaced,
  -- four times over, and leaves the panel further out each time.
  panel.group = vim.api.nvim_create_augroup("project_pinned_placement", { clear = true })
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized", "WinClosed", "WinNew" }, {
    group = panel.group,
    callback = schedule_heal,
  })

  M.render()
  M.resync()
  return panel
end

function M.detach()
  if not panel then
    return
  end
  local win, buf, group = panel.win, panel.buf, panel.group
  panel = nil
  if group then
    pcall(vim.api.nvim_del_augroup_by_id, group)
  end
  if vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  if vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end

local function anchor_win()
  local picker = panel and panel.picker
  local root = picker and not picker.closed and picker.layout and picker.layout.root
  if root and root:valid() and vim.api.nvim_win_is_valid(root.win) then
    return root.win
  end
end

--- Put the panel back above the file tree after something moved the sidebar.
---
--- The sidebar column is moved one window at a time, and a window stacked in
--- it is left wherever the move happened to leave it. Measured: resizing the
--- terminal moves the tree next to the Activity Bar and then rebuilds the
--- Picker's own windows, so the tree this panel belongs above is not even the
--- window it was above a moment ago. Hence looking the anchor up each time,
--- and hence checking after the dust settles rather than at one call site.
function M.restack()
  local anchor = anchor_win()
  if not valid_panel() or not anchor then
    return false
  end
  local function stacked()
    local mine = vim.api.nvim_win_get_position(panel.win)
    local theirs = vim.api.nvim_win_get_position(anchor)
    return mine[2] == theirs[2]
      and mine[1] < theirs[1]
      and vim.api.nvim_win_get_width(panel.win) == vim.api.nvim_win_get_width(anchor)
  end
  if stacked() then
    return false
  end
  -- Built again rather than moved. win_splitmove is the obvious tool and it
  -- does not work here: measured, every attempt failed -- the anchor had been
  -- replaced under it, or the autocommands running during the move aborted it
  -- -- and the panel was left further out each time.
  return M.attach(anchor, panel.root, panel.picker) ~= nil
end

M._panel = function()
  return panel
end

return M
