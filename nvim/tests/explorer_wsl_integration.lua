local uv = vim.uv or vim.loop
local FileOps = require("config.explorer_file_ops")
local Platform = require("config.explorer_platform")

assert(Platform.kind() == "wsl", "this integration test must run inside WSL")

local root = vim.fn.tempname()
local source = vim.fs.joinpath(root, "source")
local destination = vim.fs.joinpath(root, "destination")
local file = vim.fs.joinpath(source, "文件 clipboard.txt")
local directory = vim.fs.joinpath(source, "empty folder")
vim.fn.mkdir(directory, "p")
vim.fn.mkdir(destination, "p")
assert(vim.fn.writefile({ "windows-file-clipboard" }, file) == 0)

local ok, test_err = pcall(function()
  local copied, copy_err = Platform.copy_files({ file, directory })
  assert(copied, copy_err)
  local paths, read_err = Platform.read_files()
  assert(paths, read_err)

  local found = {}
  for _, path in ipairs(paths) do
    found[vim.fs.normalize(path)] = true
  end
  assert(found[vim.fs.normalize(file)], "Windows clipboard did not return the copied file: " .. vim.inspect(paths))
  assert(
    found[vim.fs.normalize(directory)],
    "Windows clipboard did not return the copied directory: " .. vim.inspect(paths)
  )

  local plan, plan_err = FileOps.plan(paths, destination)
  assert(plan, plan_err)
  assert(FileOps.execute(plan))
  assert(uv.fs_stat(vim.fs.joinpath(destination, vim.fs.basename(file))), "file could not be pasted from Windows")
  assert(
    uv.fs_stat(vim.fs.joinpath(destination, vim.fs.basename(directory))),
    "directory could not be pasted from Windows"
  )

  local revealed, reveal_err = Platform.reveal(file)
  assert(revealed, reveal_err)
end)

vim.fn.delete(root, "rf")
assert(ok, test_err)
print("explorer-wsl-integration-ok")
