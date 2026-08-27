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
      local commands = {
        PanelOpen = { "open_all_panels", "Restore all default project panels" },
        PanelClose = { "close_current_panel", "Close the project panel under the cursor" },
        GitPanelOpen = { "open_git_panel", "Open the project Git panel" },
        GitPanelClose = { "close", "Close the project Git panel" },
        ExplorerOpen = { "open_explorer", "Open the project Explorer panel" },
        ExplorerClose = { "close_explorer", "Close the project Explorer panel" },
        TerminalOpen = { "open_terminal", "Open the project terminal panel" },
        TerminalClose = { "close_terminal", "Hide the project terminal panel" },
      }
      for name, command in pairs(commands) do
        vim.api.nvim_create_user_command(name, function()
          require("config.git_panel")[command[1]]()
        end, { desc = command[2], force = true })
      end
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
          require("config.git_panel").toggle()
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
    end,
  },
}
