return {
  {
    "dstein64/nvim-scrollview",
    event = "VeryLazy",
    cond = vim.fn.has("nvim-0.11") == 1,
    opts = {
      base = "right",
      column = 1,
      current_only = false,
      floating_windows = true,
      hover = false,
      mode = "auto",
      mouse_primary = "left",
      signs_on_startup = {},
      visibility = "overflow",
      excluded_filetypes = {
        "blink-cmp-documentation",
        "blink-cmp-menu",
        "noice",
        "snacks_dashboard",
        "snacks_layout_box",
        "snacks_notif",
        "snacks_picker_input",
        "snacks_terminal",
        -- Sidebar panels: scrollview refreshes its floats on its own deferred
        -- schedule, 40-90ms behind a view switch, so a sidebar scrollbar pops
        -- in, out, or twitches in height two frames after every switch. The
        -- picker list already scrolls with the cursor and search, so the bar
        -- adds little; the flicker costs more.
        "snacks_picker_list",
        "project_git_panel",
        "activity_bar",
        "activity_git_slot",
        "activity_search_error",
      },
    },
  },
}
