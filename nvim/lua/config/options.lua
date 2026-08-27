-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here

-- Keep editor line numbers stable when the cursor moves. LazyVim enables
-- relative numbers by default, which makes every number except the current
-- line represent a distance rather than the file's actual line number.
vim.opt.number = true
vim.opt.relativenumber = false

-- Make invisible characters visually distinct from ordinary file content.
vim.opt.listchars = {
  space = "·",
  tab = "»·",
  trail = "·",
  nbsp = "␣",
}

-- Keep visible whitespace useful without letting it compete with file text.
-- Linking instead of hard-coding a color also adapts when the colorscheme
-- changes between light and dark variants.
local whitespace_group = vim.api.nvim_create_augroup("subtle_whitespace", { clear = true })
local function use_subtle_whitespace()
  vim.api.nvim_set_hl(0, "Whitespace", { link = "Comment" })
end

use_subtle_whitespace()
vim.api.nvim_create_autocmd("ColorScheme", {
  group = whitespace_group,
  callback = use_subtle_whitespace,
})
