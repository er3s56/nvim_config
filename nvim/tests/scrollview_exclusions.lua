-- Scrollbar behavior around the sidebar: the panels that scroll keep their
-- bars (config.activity_bar refreshes scrollview as part of every view
-- transition so the bars move with the content frame instead of trailing
-- scrollview's own 40-90ms deferral), while the Activity Bar icon strip and
-- the transient fallback slots stay excluded. The handle color is defined
-- explicitly: the default links to Visual, which Solarized Light renders as
-- a near-invisible pale pink.
local plugin = require("lazy.core.config").plugins["nvim-scrollview"]
assert(plugin, "nvim-scrollview is no longer configured")
local opts = require("lazy.core.plugin").values(plugin, "opts", false)
local excluded = {}
for _, filetype in ipairs(opts.excluded_filetypes or {}) do
  excluded[filetype] = true
end
for _, filetype in ipairs({
  -- Snacks picker lists are virtualized (the buffer only holds the visible
  -- rows), so a buffer-derived scrollbar there is permanently full-height
  -- noise that pops in and out on view switches.
  "snacks_picker_list",
  "activity_bar",
  "activity_git_slot",
  "activity_search_error",
  -- Terminals are not pinned here: scrollview refuses terminal windows
  -- upstream regardless of configuration, and config.picker_scrollbar draws
  -- the terminal's bar instead.
  "snacks_layout_box",
  "snacks_picker_input",
}) do
  assert(excluded[filetype], ("%q lost its scrollview exclusion"):format(filetype))
end
-- The Git panel is a real buffer; its scrollbar works and stays.
assert(not excluded["project_git_panel"], "the Git panel is excluded again and loses its working scrollbar")

require("lazy").load({ plugins = { "nvim-scrollview" } })
local scrollview_hl = vim.api.nvim_get_hl(0, { name = "ScrollView", link = false })
local normal_hl = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
assert(scrollview_hl.bg, "ScrollView has no explicit background; the handle falls back to a near-invisible link")
assert(scrollview_hl.bg ~= normal_hl.bg, "the ScrollView handle has the same color as the editor background")

print("scrollview-exclusions-ok")
