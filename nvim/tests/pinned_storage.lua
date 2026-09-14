local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local source = vim.fn.stdpath("config") .. "/lua/config/pinned.lua"
local path = root .. "/state/pins.json"
local first, second = dofile(source), dofile(source)
first.setup({ file = path })
second.setup({ file = path })
local original_notify = vim.notify
vim.notify = function() end
local ok, err = xpcall(function()
  assert(#first.list(root) == 0)
  assert(second.add(root, root .. "/second"))
  assert(first.add(root, root .. "/first"))
  assert(vim.deep_equal(second.list(root), { root .. "/second", root .. "/first" }), "another session's pins were lost")
  assert(second.remove(root, root .. "/first"))
  assert(vim.deep_equal(first.list(root), { root .. "/second" }), "external removal was hidden by a stale cache")
  assert(first.add("/", "/"))
  assert(first.is_pinned("/", "/"), "filesystem root did not normalize correctly")

  local before = table.concat(vim.fn.readfile(path), "\n")
  local original_rename = vim.uv.fs_rename
  vim.uv.fs_rename = function(from, to)
    if to == path then
      return nil, "ENOSPC: injected replacement failure"
    end
    return original_rename(from, to)
  end
  local added, failure = first.add(root, root .. "/failed")
  vim.uv.fs_rename = original_rename
  assert(not added and failure)
  assert(table.concat(vim.fn.readfile(path), "\n") == before, "failed persistence damaged the old store")
  assert(not second.is_pinned(root, root .. "/failed"))
  assert(vim.fn.filereadable(path .. ".lock") == 0, "failed save left a lock")

  -- A live writer is never overwritten, and failure is surfaced to callers.
  vim.fn.writefile({ tostring(vim.uv.os_getpid()) }, path .. ".lock")
  added, failure = first.add(root, root .. "/busy")
  assert(not added and failure)
  assert(table.concat(vim.fn.readfile(path), "\n") == before)
  vim.fn.delete(path .. ".lock")
  -- Invalid persisted data may be displayed as empty, but must not be silently
  -- overwritten when the user tries to add the next pin.
  vim.fn.writefile({ "{incomplete" }, path)
  assert(#second.list(root) == 0)
  added, failure = second.add(root, root .. "/corrupt")
  assert(not added and failure)
  assert(vim.fn.readfile(path)[1] == "{incomplete")
end, debug.traceback)
vim.notify = original_notify
vim.fn.delete(root, "rf")
assert(ok, err)
print("pinned-storage-ok")
