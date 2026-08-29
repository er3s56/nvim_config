-- 统一使用 Lazygit 处理 Git 操作和历史浏览。
--
-- LazyVim 已提供：
--   <leader>gg  仓库根目录
--   <leader>gG  当前工作目录
--
-- 额外键位用于打开 Lazygit 历史和工程 Git 面板；LazyVim 已有的
-- <leader>gg / <leader>gG 直接沿用默认配置，不在这里重复声明。
return {
  {
    "folke/snacks.nvim",
    init = function()
      require("config.explorer_menu").setup()
      require("config.picker_finder").setup()
      require("config.picker_scrollbar").setup()
      local ActivityBar = require("config.activity_bar")
      ActivityBar.setup()

      local function command(name, callback, opts)
        opts = opts or {}
        opts.force = true
        vim.api.nvim_create_user_command(name, callback, opts)
      end

      command("ActivityBarOpen", function(args)
        ActivityBar.open(args.args ~= "" and args.args or nil)
      end, {
        nargs = "?",
        complete = function()
          return { "explorer", "search", "git" }
        end,
        desc = "Open an Activity Bar sidebar view",
      })
      command("ActivityBarToggle", function(args)
        ActivityBar.toggle(args.args ~= "" and args.args or nil)
      end, {
        nargs = "?",
        complete = function()
          return { "explorer", "search", "git" }
        end,
        desc = "Toggle an Activity Bar sidebar view",
      })
      command("ActivityBarClose", function()
        ActivityBar.close()
      end, { desc = "Collapse the Activity Bar sidebar" })
      command("SearchPanelOpen", function()
        ActivityBar.open("search")
      end, { desc = "Open the project Search sidebar" })
      command("SearchPanelClose", function()
        local state = ActivityBar.current()
        if state and state.view == "search" then
          ActivityBar.close()
        end
      end, { desc = "Close the project Search sidebar" })
      command("ExplorerOpen", function()
        ActivityBar.open("explorer")
      end, { desc = "Open the project Explorer sidebar" })
      command("ExplorerClose", function()
        local state = ActivityBar.current()
        if state and state.view == "explorer" then
          ActivityBar.close()
        end
      end, { desc = "Close the project Explorer sidebar" })
      command("GitPanelOpen", function()
        ActivityBar.open("git")
      end, { desc = "Open the project Git sidebar" })
      command("GitPanelClose", function()
        local state = ActivityBar.current()
        if state and state.view == "git" then
          ActivityBar.close()
        end
      end, { desc = "Close the project Git sidebar" })
      command("PanelOpen", function()
        ActivityBar.open_all_panels()
      end, { desc = "Restore the Activity Bar, sidebar, and project terminal" })
      command("PanelClose", function()
        ActivityBar.close_current_panel()
      end, { desc = "Close the project panel under the cursor" })
      command("TerminalOpen", function()
        require("config.git_panel").open_terminal()
      end, { desc = "Open the project terminal panel" })
      command("TerminalClose", function()
        require("config.git_panel").close_terminal()
      end, { desc = "Hide the project terminal panel" })
      vim.api.nvim_create_user_command("PanelBufferOpen", function(command)
        require("config.git_panel").open_buffer(command.args)
      end, {
        nargs = 1,
        desc = "Open a Bufferline tab in the central editor",
        force = true,
      })
    end,
    opts = {
      picker = {
        sources = {
          explorer = {
            hidden = true,
            ignored = true,
          },
        },
      },
      terminal = {
        win = {
          keys = {
            q = { function() end, desc = "Disabled in project panels" },
            -- Keep terminal keyboard input transparent. Panel selection is
            -- mouse-driven, so shell/TUI programs should receive every key.
            nav_h = false,
            nav_j = false,
            nav_k = false,
            nav_l = false,
            hide_slash = false,
            hide_underscore = false,
            term_normal = false,
          },
        },
      },
    },
    keys = {
      {
        "<leader>gv",
        function()
          Snacks.lazygit({ cwd = LazyVim.root.git() })
        end,
        desc = "Lazygit 仓库",
      },
      {
        "<leader>gV",
        function()
          Snacks.lazygit.log({ cwd = LazyVim.root.git() })
        end,
        desc = "Lazygit 提交历史",
      },
      {
        "<leader>gF",
        function()
          Snacks.lazygit.log_file()
        end,
        desc = "Lazygit 当前文件历史",
      },
      {
        "<leader>gE",
        function()
          require("config.activity_bar").toggle("git")
        end,
        desc = "显示/隐藏工程 Git 面板",
      },
    },
  },
  {
    "akinsho/bufferline.nvim",
    keys = {
      {
        "<S-h>",
        function()
          require("config.git_panel").cycle_buffer(-1)
        end,
        desc = "Previous buffer tab",
      },
      {
        "<S-l>",
        function()
          require("config.git_panel").cycle_buffer(1)
        end,
        desc = "Next buffer tab",
      },
      {
        "[b",
        function()
          require("config.git_panel").cycle_buffer(-1)
        end,
        desc = "Previous buffer tab",
      },
      {
        "]b",
        function()
          require("config.git_panel").cycle_buffer(1)
        end,
        desc = "Next buffer tab",
      },
    },
    opts = function(_, opts)
      opts.options = opts.options or {}
      opts.options.always_show_bufferline = true
      -- Keep Bufferline's scheduled command path so real mouse clicks also
      -- trigger its normal UI refresh after the central editor is updated.
      opts.options.left_mouse_command = "PanelBufferOpen %d"
      -- Neovim's tabline spans the whole screen. Reserve the Activity Bar and
      -- the sidebar so buffer tabs begin above the central editor, the way an
      -- editor tab strip is expected to sit. Bufferline sizes an offset from
      -- the matched window, and only ever matches the first or last window of
      -- the layout row, so the sidebar in between is covered by padding that
      -- `config.activity_bar` keeps in sync with the real layout.
      opts.options.offsets = opts.options.offsets or {}
      table.insert(opts.options.offsets, 1, {
        filetype = "activity_bar",
        text = "",
        highlight = "Normal",
      })
    end,
  },
}
