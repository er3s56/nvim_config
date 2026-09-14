-- <C-f> belongs to Find in File and <C-b> to the sidebar (config/keymaps.lua).
-- Noice binds both to scroll a hover document and falls back to paging; take
-- the keys back so they do their job whether or not a document is up.
return {
  "folke/noice.nvim",
  keys = {
    { "<c-f>", false, mode = { "i", "n", "s" } },
    { "<c-b>", false, mode = { "i", "n", "s" } },
  },
}
