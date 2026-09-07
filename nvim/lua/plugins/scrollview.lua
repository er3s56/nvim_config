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
      -- Mark where the changes are on the scrollbar itself, the way an
      -- overview ruler does: scrolled away from a hunk you can still see that
      -- one is there, and roughly how far down.
      --
      -- The marks come from a contrib module that has to be set up after
      -- gitsigns, and gitsigns is not loaded when this runs -- scrollview
      -- arrives on VeryLazy, gitsigns only once a real file is open, so on a
      -- dashboard start this would otherwise wire itself to nothing and say
      -- so to no one. Take whichever of the two moments comes second.
      local function attach_gitsigns()
        if not package.loaded["gitsigns"] then
          return false
        end
        local ok, err = pcall(function()
          require("scrollview.contrib.gitsigns").setup({})
        end)
        if not ok then
          vim.notify(("Scrollbar git marks are unavailable: %s"):format(err), vim.log.levels.WARN)
        end
        return true
      end

      if not attach_gitsigns() then
        vim.api.nvim_create_autocmd("User", {
          group = vim.api.nvim_create_augroup("project_scrollview_gitsigns", { clear = true }),
          pattern = "LazyLoad",
          callback = function(args)
            if args.data == "gitsigns.nvim" then
              return attach_gitsigns()
            end
          end,
        })
      end
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
