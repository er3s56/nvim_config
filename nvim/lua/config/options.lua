-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here

-- The leader is pressed hundreds of times a day and space is the one key that
-- cannot be spared for it: as a prefix it makes every plain <Space> wait for
-- 'timeout' before it moves the cursor. A backslash has no meaning of its own
-- in Normal mode -- Vim reserves it for exactly this -- so nothing is shadowed
-- by taking it.
--
-- Both are set here because a leader is substituted when a mapping is defined,
-- not when it is pressed: this file is loaded before any plugin has defined
-- one, and setting it anywhere later would move nothing. And they are set to
-- different keys because <localleader> exists to keep filetype plugins out of
-- the global namespace; sharing a key gives that up for nothing.
vim.g.mapleader = "\\"
vim.g.maplocalleader = ","

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
local function use_subtle_whitespace()
  vim.api.nvim_set_hl(0, "Whitespace", { link = "Comment" })
end

-- A diff that keeps the file's own colours.
--
-- Solarized colours diff lines by foreground alone -- DiffText and DiffDelete
-- go further and reverse it, filling the line. An added line's text is painted
-- DiffAdd green, and every syntax colour on it is lost. That green is also
-- Statement's, so a commented-out `if` inside an added block is drawn in
-- exactly the colour a live keyword would be: the diff says "this line is new"
-- by taking away what the line says it is.
--
-- Tint the background instead, the way VSCode and every other side-by-side
-- diff does, and leave the foreground to whoever was already colouring it. The
-- tint is mixed from the theme's own diff colour and its own background, so a
-- light theme gets a light wash, a dark one a dark wash, and switching themes
-- carries it along.
local DIFF_TINTS = {
  DiffAdd = 0.14,
  DiffChange = 0.14,
  DiffDelete = 0.14,
  -- The stretch that actually differs carries a stronger wash: it is what the
  -- eye is looking for. DiffTextAdd links here and follows on its own.
  DiffText = 0.30,
}

local function blend(accent, base, amount)
  local function channel(shift)
    local top = math.floor(accent / shift) % 256
    local bottom = math.floor(base / shift) % 256
    return math.floor(top * amount + bottom * (1 - amount) + 0.5)
  end
  return channel(65536) * 65536 + channel(256) * 256 + channel(1)
end

-- What the theme meant each group to be, remembered before it is overwritten:
-- read a second time, a group would only report the tint we just gave it, and
-- tinting a tint walks the colour off towards the background.
local diff_accents = {}

local function tint_diffs()
  local base = vim.api.nvim_get_hl(0, { name = "Normal", link = false }).bg
  if not base then
    return
  end
  for group, amount in pairs(DIFF_TINTS) do
    if diff_accents[group] == nil then
      -- Only a group that paints a foreground has anything to rescue: one
      -- already working by background lets the syntax colours through, and
      -- washing it out would be the damage rather than the repair.
      diff_accents[group] = vim.api.nvim_get_hl(0, { name = group, link = false }).fg or false
    end
    local accent = diff_accents[group]
    if accent then
      local tint = blend(accent, base, amount)
      -- DiffDelete paints the filler rows opposite a deletion, whose text is
      -- the fill character repeated. Giving it the tint as a foreground too
      -- leaves a flat block rather than a row of loud stripes.
      local foreground = nil
      if group == "DiffDelete" then
        foreground = tint
      end
      vim.api.nvim_set_hl(0, group, { bg = tint, fg = foreground })
    end
  end
end

-- Both of the above are ours, and a colorscheme replaces them wholesale.
use_subtle_whitespace()
tint_diffs()
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("theme_tweaks", { clear = true }),
  callback = function()
    use_subtle_whitespace()
    -- The theme has just put its own diff colours back; read them again.
    diff_accents = {}
    tint_diffs()
  end,
})
