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
        -- Snacks virtualizes its picker lists: the buffer only ever holds
        -- the visible rows (measured: 66 items, 40 buffer lines), so a
        -- scrollbar derived from buffer lines is permanently full-height at
        -- the top -- pure noise that pops in and out on view switches. The
        -- Git panel is a real buffer and keeps its (working) bar;
        -- `config.activity_bar` refreshes scrollview on every transition so
        -- that bar moves with the content frame.
        "snacks_picker_list",
        "activity_bar",
        "activity_git_slot",
        "activity_search_error",
      },
    },
    config = function(_, opts)
      require("scrollview").setup(opts)
      -- The default handle links to Visual, which Solarized Light renders as
      -- a pale pink barely distinguishable from the background. Use the
      -- palette's content greys instead: base1 for the handle, base01 while
      -- it is being dragged.
      local function scrollbar_colors()
        vim.api.nvim_set_hl(0, "ScrollView", { bg = "#657b83" })
        vim.api.nvim_set_hl(0, "ScrollViewHover", { bg = "#586e75" })
        vim.api.nvim_set_hl(0, "ScrollViewClicked", { bg = "#073642" })
      end
      scrollbar_colors()
      vim.api.nvim_create_autocmd("ColorScheme", {
        group = vim.api.nvim_create_augroup("project_scrollview_colors", { clear = true }),
        callback = scrollbar_colors,
      })
    end,
  },
}
