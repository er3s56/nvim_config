-- The sidebar scrollbar was the last visible switch flicker: scrollview
-- refreshes its floating bars on its own deferred schedule, 40-90ms behind a
-- view switch, so a bar popped in, out, or twitched in height two frames
-- after every switch. The fix is configuration -- the sidebar panels are
-- excluded -- and this pins that configuration.
local plugin = require("lazy.core.config").plugins["nvim-scrollview"]
assert(plugin, "nvim-scrollview is no longer configured")
local opts = require("lazy.core.plugin").values(plugin, "opts", false)
local excluded = {}
for _, filetype in ipairs(opts.excluded_filetypes or {}) do
  excluded[filetype] = true
end
for _, filetype in ipairs({
  "snacks_picker_list",
  "project_git_panel",
  "activity_bar",
  "activity_git_slot",
  "activity_search_error",
  "snacks_terminal",
  "snacks_layout_box",
  "snacks_picker_input",
}) do
  assert(
    excluded[filetype],
    ("scrollview draws scrollbars on %q again; its deferred refresh makes them flicker on every view switch"):format(
      filetype
    )
  )
end

print("scrollview-exclusions-ok")
