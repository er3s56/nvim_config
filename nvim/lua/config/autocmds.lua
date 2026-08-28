-- Autocmds are automatically loaded on the VeryLazy event
-- Default autocmds that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/autocmds.lua
--
-- Add any additional autocmds here
-- with `vim.api.nvim_create_autocmd`
--
-- Or remove existing autocmds by their group name (which is prefixed with `lazyvim_` for the defaults)
-- e.g. vim.api.nvim_del_augroup_by_name("lazyvim_wrap_spell")

-- 工程启动后自动创建类似 VS Code 的布局：
-- 左侧文件树、中央编辑区、下方终端。
-- 本文件由 LazyVim 在 VeryLazy 阶段加载，因此直接 schedule 到本轮启动末尾。
vim.schedule(function()
  if #vim.api.nvim_list_uis() == 0 or vim.o.diff then
    return
  end

  local ft = vim.bo.filetype
  if vim.tbl_contains({ "gitcommit", "gitrebase" }, ft) then
    return
  end

  local root = LazyVim.root()
  local argv = vim.fn.argv()
  local opened_directory = #argv == 1 and vim.fn.isdirectory(argv[1]) == 1
  local project_marker = vim.fs.find({
    ".git",
    "Makefile",
    "CMakeLists.txt",
    "package.json",
    "Cargo.toml",
    "go.mod",
  }, { path = root, upward = true })[1]

  -- `nvim`、`nvim .`，或者直接打开工程内文件时启用该布局。
  if #argv > 0 and not opened_directory and not project_marker then
    return
  end

  require("config.activity_bar").open_all_panels()
end)
