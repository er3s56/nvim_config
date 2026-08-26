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
      },
    },
  },
}
