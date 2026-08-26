local uv = vim.uv or vim.loop
local FileOps = require("config.explorer_file_ops")

local function assert_equal(expected, actual, message)
  if not vim.deep_equal(expected, actual) then
    error(("%s\nexpected: %s\nactual:   %s"):format(message, vim.inspect(expected), vim.inspect(actual)))
  end
end

local function write(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  assert_equal(0, vim.fn.writefile(type(lines) == "table" and lines or { lines }, path), "write failed")
end

local function read(path)
  return table.concat(vim.fn.readfile(path), "\n")
end

local root = vim.fn.tempname()
local source = vim.fs.joinpath(root, "source")
local destination = vim.fs.joinpath(root, "destination")
vim.fn.mkdir(source, "p")
vim.fn.mkdir(destination, "p")

local ok, test_err = pcall(function()
  write(vim.fs.joinpath(source, "single.txt"), "single")
  write(vim.fs.joinpath(source, "folder", ".hidden"), "hidden")
  write(vim.fs.joinpath(source, "folder", "nested", "value.txt"), "nested")
  vim.fn.mkdir(vim.fs.joinpath(source, "folder", "empty"), "p")
  local linked, link_err = uv.fs_symlink("single.txt", vim.fs.joinpath(source, "single-link"))
  assert(linked, link_err)

  local plan, plan_err = FileOps.plan({
    vim.fs.joinpath(source, "single.txt"),
    vim.fs.joinpath(source, "folder"),
    vim.fs.joinpath(source, "single-link"),
  }, destination)
  assert(plan, plan_err)
  assert_equal(0, #plan.conflicts, "fresh destination must not conflict")
  assert(FileOps.execute(plan))
  assert_equal("single", read(vim.fs.joinpath(destination, "single.txt")), "single file was not copied")
  assert_equal("hidden", read(vim.fs.joinpath(destination, "folder", ".hidden")), "hidden file was not copied")
  assert_equal("nested", read(vim.fs.joinpath(destination, "folder", "nested", "value.txt")), "nested file missing")
  assert_equal(
    "directory",
    uv.fs_lstat(vim.fs.joinpath(destination, "folder", "empty")).type,
    "empty directory missing"
  )
  assert_equal("link", uv.fs_lstat(vim.fs.joinpath(destination, "single-link")).type, "symlink was dereferenced")
  assert_equal("single.txt", uv.fs_readlink(vim.fs.joinpath(destination, "single-link")), "symlink target changed")

  write(vim.fs.joinpath(source, "single.txt"), "new")
  local conflict = assert(FileOps.plan({ vim.fs.joinpath(source, "single.txt") }, destination))
  assert_equal(1, #conflict.conflicts, "file collision was not reported")
  local copied = FileOps.execute(conflict)
  assert_equal(nil, copied, "conflicting copy must wait for overwrite confirmation")
  assert_equal("single", read(vim.fs.joinpath(destination, "single.txt")), "cancelled overwrite changed the file")
  assert(FileOps.execute(conflict, { overwrite = true }))
  assert_equal("new", read(vim.fs.joinpath(destination, "single.txt")), "confirmed overwrite did not replace file")

  write(vim.fs.joinpath(destination, "folder", "keep.txt"), "keep")
  write(vim.fs.joinpath(source, "folder", "nested", "value.txt"), "replaced")
  local merge = assert(FileOps.plan({ vim.fs.joinpath(source, "folder") }, destination))
  assert(#merge.conflicts >= 2, "directory merge conflicts were not discovered")
  assert(FileOps.execute(merge, { overwrite = true }))
  assert_equal(
    "keep",
    read(vim.fs.joinpath(destination, "folder", "keep.txt")),
    "directory merge removed destination-only file"
  )
  assert_equal(
    "replaced",
    read(vim.fs.joinpath(destination, "folder", "nested", "value.txt")),
    "directory merge did not replace conflict"
  )

  write(vim.fs.joinpath(source, "type-conflict"), "file")
  vim.fn.mkdir(vim.fs.joinpath(destination, "type-conflict"), "p")
  write(vim.fs.joinpath(destination, "type-conflict", "old.txt"), "old")
  local type_conflict = assert(FileOps.plan({ vim.fs.joinpath(source, "type-conflict") }, destination))
  assert(FileOps.execute(type_conflict, { overwrite = true }))
  assert_equal(
    "file",
    uv.fs_lstat(vim.fs.joinpath(destination, "type-conflict")).type,
    "file/directory conflict was not replaced"
  )

  local child = vim.fs.joinpath(source, "folder", "child")
  vim.fn.mkdir(child, "p")
  local descendant, descendant_err = FileOps.plan({ vim.fs.joinpath(source, "folder") }, child)
  assert_equal(nil, descendant, "directory could be copied into its descendant")
  assert(descendant_err:find("descendants", 1, true), descendant_err)

  local same, same_err = FileOps.plan({ vim.fs.joinpath(source, "single.txt") }, source)
  assert_equal(nil, same, "file could be pasted into its current directory")
  assert(same_err:find("current directory", 1, true), same_err)
end)

vim.fn.delete(root, "rf")
assert(ok, test_err)
print("explorer-file-ops-ok")
