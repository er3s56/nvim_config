-- <C-f> belongs to Find in File (config/keymaps.lua). Noice binds it to scroll
-- a hover document and falls back to page-down; take the key back so the strip
-- opens whether or not a document is up.
return {
  "folke/noice.nvim",
  keys = {
    { "<c-f>", false, mode = { "i", "n", "s" } },
  },
}
