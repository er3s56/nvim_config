local FileReload = require("config.file_reload")

local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/one", "p")
vim.fn.mkdir(root .. "/two", "p")
local a = root .. "/one/a.txt"
local b = root .. "/one/b.txt"
local c = root .. "/two/c.txt"
for _, path in ipairs({ a, b, c }) do
  assert(vim.fn.writefile({ "ORIGINAL" }, path) == 0)
end

local original_cwd = vim.fn.getcwd(0)

local function watched_dirs()
  local dirs = {}
  for dir in pairs(FileReload._watchers) do
    dirs[#dirs + 1] = dir
  end
  table.sort(dirs)
  return dirs
end

local ok, test_error = pcall(function()
  vim.cmd.cd(vim.fn.fnameescape(root))
  FileReload.setup()

  vim.cmd.edit(vim.fn.fnameescape(a))
  local buf_a = vim.api.nvim_get_current_buf()
  assert(#watched_dirs() == 1, "opening a file did not start a directory watcher")
  assert(watched_dirs()[1] == FileReload._buffer_dir(buf_a), "the watcher is not on the file's directory")

  -- A second file in the same directory must share the one watcher. Compare
  -- the handle itself, not just the directory count: replacing the entry would
  -- keep the count at one while quietly dropping the previous handle unclosed.
  local shared_dir = watched_dirs()[1]
  local shared_handle = FileReload._watchers[shared_dir].handle
  vim.cmd.edit(vim.fn.fnameescape(b))
  local buf_b = vim.api.nvim_get_current_buf()
  assert(#watched_dirs() == 1, "a second file in the same directory started another watcher")
  assert(
    FileReload._watchers[shared_dir].handle == shared_handle,
    "a second file in the same directory replaced the watcher instead of sharing it"
  )
  assert(not shared_handle:is_closing(), "the shared watcher handle was closed while still in use")

  -- A file elsewhere needs its own.
  vim.cmd.edit(vim.fn.fnameescape(c))
  local buf_c = vim.api.nvim_get_current_buf()
  assert(#watched_dirs() == 2, "a file in another directory did not start its own watcher")

  -- The whole point: a change made by another process reaches Neovim with no
  -- interaction at all. Assert that the watcher ran a check rather than that
  -- the buffer content changed: performing the reload is Neovim's job, and
  -- headless Neovim defers it until a buffer is entered because nothing
  -- redraws. The reload itself is covered end to end in a real TUI.
  local before = FileReload._checks()
  assert(vim.fn.writefile({ "CHANGED-EXTERNALLY" }, a) == 0)
  assert(
    vim.wait(5000, function()
      return FileReload._checks() > before
    end, 50),
    "a change made outside Neovim never woke the directory watcher"
  )

  -- Most tools write by renaming a temp file over the target. An fs_event on
  -- the file itself stops delivering after the first such replace, which is
  -- why the watch is on the directory.
  for round = 1, 2 do
    before = FileReload._checks()
    local temp = root .. "/one/.swap"
    assert(vim.fn.writefile({ "ATOMIC-" .. round }, temp) == 0)
    assert(vim.uv.fs_rename(temp, a), "could not replace the file atomically")
    assert(
      vim.wait(5000, function()
        return FileReload._checks() > before
      end, 50),
      ("the watcher stopped delivering after atomic replace %d"):format(round)
    )
  end

  -- An fs_event follows the directory's inode, so replacing the directory
  -- itself -- `rm -rf build && make`, a checkout that removes and restores it
  -- -- leaves the watch alive but permanently silent. Removal emits events
  -- first, which is the chance to re-arm.
  local watched = watched_dirs()[1]
  local stale_handle = FileReload._watchers[watched].handle
  assert(vim.fn.delete(root .. "/one", "rf") == 0, "could not remove the watched directory")
  vim.fn.mkdir(root .. "/one", "p")
  assert(vim.fn.writefile({ "REBUILT" }, a) == 0)
  assert(
    vim.wait(5000, function()
      local entry = FileReload._watchers[watched]
      return entry ~= nil and entry.handle ~= stale_handle
    end, 50),
    "the watcher was not re-armed after its directory was replaced"
  )
  assert(stale_handle:is_closing(), "the stale handle was replaced without being closed")
  before = FileReload._checks()
  assert(vim.fn.writefile({ "AFTER-REBUILD" }, a) == 0)
  assert(
    vim.wait(5000, function()
      return FileReload._checks() > before
    end, 50),
    "the re-armed watcher does not deliver"
  )
  -- b lives in that directory too and must still be covered by the new watch.
  assert(FileReload._watchers[watched].buffers[buf_b], "the re-armed watch lost one of its buffers")
  assert(vim.fn.writefile({ "ORIGINAL" }, b) == 0)

  -- The harder shape: the directory stays gone for a while (`rm -rf build`,
  -- rebuild later) and the buffer is never left, so nothing else would put the
  -- watch back. Fall back to the nearest ancestor that does exist, and move
  -- back down once the directory returns.
  assert(vim.fn.delete(root .. "/one", "rf") == 0, "could not remove the watched directory")
  assert(
    vim.wait(5000, function()
      local entry = FileReload._watchers[watched]
      return entry ~= nil and entry.target ~= watched
    end, 50),
    "a missing directory did not fall back to an ancestor watch"
  )
  assert(vim.fn.isdirectory(FileReload._watchers[watched].target) == 1, "the fallback watch is not on a real directory")
  vim.fn.mkdir(root .. "/one", "p")
  assert(vim.fn.writefile({ "REAPPEARED" }, a) == 0)
  assert(
    vim.wait(5000, function()
      local entry = FileReload._watchers[watched]
      return entry ~= nil and entry.target == watched
    end, 50),
    "the watch did not move back down once the directory reappeared"
  )
  before = FileReload._checks()
  assert(vim.fn.writefile({ "AFTER-REAPPEAR" }, a) == 0)
  assert(
    vim.wait(5000, function()
      return FileReload._checks() > before
    end, 50),
    "the watch restored onto the recreated directory does not deliver"
  )
  assert(vim.fn.writefile({ "ORIGINAL" }, b) == 0)

  -- A write in another watched directory wakes that directory's watcher too.
  before = FileReload._checks()
  assert(vim.fn.writefile({ "ELSEWHERE" }, c) == 0)
  assert(
    vim.wait(5000, function()
      return FileReload._checks() > before
    end, 50),
    "the second directory watcher never fired"
  )

  -- Watchers are released with their last buffer, not leaked per open file.
  local handles = {}
  for _, entry in pairs(FileReload._watchers) do
    handles[#handles + 1] = entry.handle
  end
  assert(#handles == 2, "expected one handle per watched directory")
  vim.api.nvim_buf_delete(buf_a, { force = true })
  assert(#watched_dirs() == 2, "the directory watcher went away while another buffer still used it")
  vim.api.nvim_buf_delete(buf_b, { force = true })
  assert(#watched_dirs() == 1, "the directory watcher outlived its last buffer")
  vim.api.nvim_buf_delete(buf_c, { force = true })
  assert(#watched_dirs() == 0, "a directory watcher was left behind")
  for index, handle in ipairs(handles) do
    assert(handle:is_closing(), ("watcher %d was released without closing its handle"):format(index))
  end

  -- Reopening starts over cleanly rather than reusing a closed handle.
  vim.cmd.edit(vim.fn.fnameescape(a))
  assert(#watched_dirs() == 1, "reopening a file did not start a fresh watcher")
  local reopened = vim.api.nvim_get_current_buf()
  local before_reopen = FileReload._checks()
  assert(vim.fn.writefile({ "AFTER-REOPEN" }, a) == 0)
  assert(
    vim.wait(5000, function()
      return FileReload._checks() > before_reopen
    end, 50),
    "the watcher started on reopen does not deliver"
  )
  vim.api.nvim_buf_delete(reopened, { force = true })
end)

vim.cmd.cd(vim.fn.fnameescape(original_cwd))
vim.fn.delete(root, "rf")
assert(ok, test_error)

print("file-reload-ok")
