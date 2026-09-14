local F = require("config.explorer_file_ops")
local uv = vim.uv
local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/source", "p")
vim.fn.mkdir(root .. "/destination", "p")
local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  assert(vim.fn.writefile({ text }, path) == 0)
end
local function read(path)
  return table.concat(vim.fn.readfile(path), "\n")
end
local ok, err = xpcall(function()
  local source, target = root .. "/source/file", root .. "/destination/file"
  write(source, "new content")
  write(target, "valuable original")
  local plan = assert(F.plan({ source }, root .. "/destination"))
  -- Inject a copy failure without relying on root/non-root permission semantics.
  local original_copy = uv.fs_copyfile
  uv.fs_copyfile = function()
    return nil, "ENOSPC: injected full disk"
  end
  local success, failure = F.execute(plan, { overwrite = true })
  uv.fs_copyfile = original_copy
  assert(not success and failure:find("ENOSPC", 1, true))
  assert(read(target) == "valuable original", "failed copy deleted the original")
  assert(F.execute(plan, { overwrite = true }))
  assert(read(target) == "new content")

  -- A directory replacing a file also has to finish copying before the old
  -- file moves aside. Failure in any child must preserve that old file.
  source, target = root .. "/source/folder", root .. "/destination/folder"
  write(source .. "/child", "child")
  write(target, "original file")
  plan = assert(F.plan({ source }, root .. "/destination"))
  uv.fs_copyfile = function()
    return nil, "EACCES: injected unreadable source"
  end
  success, failure = F.execute(plan, { overwrite = true })
  uv.fs_copyfile = original_copy
  assert(not success)
  assert(read(target) == "original file", "failed directory replacement destroyed the old file")

  -- Failure during the final rename restores the old type-conflicting entry.
  local original_rename = uv.fs_rename
  uv.fs_rename = function(from, to)
    if to == target and from:match("/item$") then
      return nil, "EACCES: injected rename failure"
    end
    return original_rename(from, to)
  end
  success, failure = F.execute(plan, { overwrite = true })
  uv.fs_rename = original_rename
  assert(not success)
  assert(read(target) == "original file", "failed install did not restore its backup")

  assert(uv.fs_chmod(source, 365)) -- 0555
  assert(F.execute(plan, { overwrite = true }))
  assert(read(target .. "/child") == "child", "read-only directory could not be copied")
  assert(bit.band(uv.fs_stat(target).mode, 511) == 365, "directory mode was not restored")
  assert(uv.fs_chmod(source, 493))
  assert(uv.fs_chmod(target, 493))
  for _, name in ipairs(vim.fn.readdir(root .. "/destination")) do
    assert(not name:match("^%.nvim%-copy%-"), "copy leaked its staging directory")
  end
end, debug.traceback)
pcall(uv.fs_chmod, root .. "/source/folder", 493)
pcall(uv.fs_chmod, root .. "/destination/folder", 493)
vim.fn.delete(root, "rf")
assert(ok, err)
print("explorer-copy-failures-ok")
