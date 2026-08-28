-- Keep loaded buffers in step with files changed outside Neovim.
--
-- 'autoread' only reloads when Neovim actually looks, and looking is what
-- `:checktime` does. LazyVim runs it on FocusGained, TermClose and TermLeave,
-- which misses the common case of a background process -- a formatter, a build
-- in watch mode, an agent -- rewriting a file while Neovim keeps focus.
--
-- Watch the *directory* of every loaded file buffer rather than the file
-- itself: measured, an fs_event on a file stops delivering for good after the
-- first atomic replace (write temp, rename over), which is how most tools
-- write. A directory watch keeps reporting. This is also the shape editors
-- with live reload use, except they watch the whole workspace recursively;
-- here one watch per directory that actually has a buffer open is enough.
local M = {}

local DEBOUNCE = 100

-- dir -> { handle = uv_fs_event, buffers = { [buf] = true } }
local watchers = {}
local generation = 0
local deferred = false
local setup_done = false
-- Counts completed checks so tests can assert the watcher fired without
-- depending on when Neovim performs the reload itself.
local checks = 0

local function buffer_dir(buf)
  if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_buf_is_loaded(buf) then
    return
  end
  if vim.bo[buf].buftype ~= "" then
    return
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    return
  end
  -- Deliberately not required to exist: a directory that is being rebuilt
  -- still identifies the buffer's watch.
  return vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(name, ":p")))
end

-- An fs_event can only be started on a directory that exists. While the real
-- one is missing, watch the closest ancestor that is there, so its recreation
-- produces an event and the watch can move back down onto it.
local function nearest_existing(dir)
  local path = dir
  for _ = 1, 64 do
    if vim.fn.isdirectory(path) == 1 then
      return path
    end
    local parent = vim.fs.dirname(path)
    if not parent or parent == path then
      return nil
    end
    path = parent
  end
end

-- Directories that produced events since the last check, so their watches can
-- be renewed once the burst settles. Assigned below; the watch callback needs
-- `rearm` before it is defined.
local dirty = {}
local rearm

local function check_now()
  -- Reloading in the middle of typing would interrupt the insert, and a
  -- conflict prompt there is worse still. InsertLeave picks this back up.
  if vim.api.nvim_get_mode().mode:sub(1, 1) == "i" then
    deferred = true
    return
  end
  deferred = false
  checks = checks + 1
  pcall(vim.cmd.checktime)
  -- An fs_event is bound to the directory it was started on, and nothing
  -- rebinds it when that directory is replaced (`rm -rf build && make`, a
  -- checkout that removes and restores it). Measured: the watch then stays
  -- alive and permanently silent, and the inode number is often reused, so
  -- there is nothing to compare against to detect it. Renewing the watch once
  -- per burst sidesteps detection entirely -- removing a directory does emit
  -- events, which is what gets us here while there is still time to act.
  for dir in pairs(dirty) do
    dirty[dir] = nil
    rearm(dir)
  end
end

local function queue_check()
  generation = generation + 1
  local request = generation
  vim.defer_fn(function()
    if request == generation then
      check_now()
    end
  end, DEBOUNCE)
end

local function release_dir(dir)
  local entry = watchers[dir]
  if not entry then
    return
  end
  watchers[dir] = nil
  if entry.handle and not entry.handle:is_closing() then
    entry.handle:stop()
    entry.handle:close()
  end
end

local function watch(buf)
  local dir = buffer_dir(buf)
  if not dir then
    return
  end
  local entry = watchers[dir]
  if entry then
    entry.buffers[buf] = true
    return
  end
  local target = nearest_existing(dir)
  if not target then
    return
  end
  local handle = vim.uv.new_fs_event()
  if not handle then
    return
  end
  -- A directory watch reports every entry in it, so a build writing beside the
  -- open file also wakes us. The debounce collapses that into one checktime.
  local started = handle:start(target, {}, function(err)
    if err then
      return
    end
    vim.schedule(function()
      dirty[dir] = true
      queue_check()
    end)
  end)
  if not started then
    handle:close()
    return
  end
  watchers[dir] = { handle = handle, buffers = { [buf] = true }, target = target }
end

local function release(buf)
  for dir, entry in pairs(watchers) do
    if entry.buffers[buf] then
      entry.buffers[buf] = nil
      if next(entry.buffers) == nil then
        release_dir(dir)
      end
    end
  end
end

-- Start over, re-resolving which directory to watch. This both renews a watch
-- whose directory was replaced and moves it back down from an ancestor once the
-- real directory exists again.
function rearm(dir)
  local entry = watchers[dir]
  if not entry then
    return
  end
  local buffers = vim.tbl_keys(entry.buffers)
  release_dir(dir)
  for _, buf in ipairs(buffers) do
    watch(buf)
  end
end

-- A renamed buffer may belong to a different directory now, and the old one
-- may no longer have any buffer left to justify its watch.
local function rewatch(buf)
  release(buf)
  watch(buf)
end

function M.setup()
  if setup_done then
    return
  end
  setup_done = true

  local group = vim.api.nvim_create_augroup("project_file_reload", { clear = true })
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
    group = group,
    callback = function(event)
      watch(event.buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufFilePost", {
    group = group,
    callback = function(event)
      rewatch(event.buf)
    end,
  })
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = group,
    callback = function(event)
      release(event.buf)
    end,
  })
  vim.api.nvim_create_autocmd("InsertLeave", {
    group = group,
    callback = function()
      if deferred then
        check_now()
      end
    end,
  })
  -- Buffers that already existed before this module loaded.
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    watch(buf)
  end
end

function M._checks()
  return checks
end

M._rearm = rearm
M._watchers = watchers
M._watch = watch
M._release = release
M._buffer_dir = buffer_dir

return M
