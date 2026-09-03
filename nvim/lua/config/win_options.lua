-- Window options that stay in the window.
--
-- `vim.wo[win].number = false` reads as `:setlocal`, and `:help vim.wo` says
-- as much, but in Neovim 0.12-dev it behaves like `:set` whenever `win` is the
-- current window: measured, the global value follows along, and every window
-- opened afterwards starts from it. A sidebar turning off its own line numbers
-- was quietly deciding that new windows had none either -- and a diff putting
-- an editor window back the way it found it was doing the same.
--
-- nvim_set_option_value with an explicit scope does what the name promises, so
-- every window option in this configuration is set through here.

local M = {}

--- Set window-local options on `win`, leaving the global defaults alone.
--- Invalid windows and option names raise, exactly as assigning them would.
function M.set(win, options)
  for name, value in pairs(options) do
    vim.api.nvim_set_option_value(name, value, { scope = "local", win = win })
  end
end

return M
