local ContextMenu = require("config.context_menu")
local ProjectPaths = require("config.project_paths")

local M = {}

local function listed(buf)
  return vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buflisted
end

local function close_buffers(buffers)
  for _, buf in ipairs(buffers) do
    if listed(buf) then
      -- Use the same close behavior as the tab's close button, including the
      -- save/cancel prompt for modified files. Never force a batch close.
      Snacks.bufdelete(buf)
    end
  end
end

function M.open(buf)
  local mouse = vim.fn.getmousepos()
  -- Tabline callbacks run under textlock. Keep the clicked buffer ID rather
  -- than using the current buffer, which can belong to a different tab/panel.
  vim.schedule(function()
    if not listed(buf) then
      return
    end
    local others, right, found = {}, {}, false
    for _, element in ipairs(require("bufferline").get_elements().elements) do
      if element.id == buf then
        found = true
      else
        others[#others + 1] = element.id
        if found then
          right[#right + 1] = element.id
        end
      end
    end
    local path = vim.api.nvim_buf_get_name(buf)
    local has_path = path ~= "" and vim.bo[buf].buftype == "" and not path:match("^%w[%w+.-]*://")
    vim.cmd.stopinsert()
    ContextMenu.open({
      { label = path ~= "" and vim.fn.fnamemodify(path, ":t") or "[No Name]", enabled = false },
      { separator = true },
      {
        label = "Close",
        action = function()
          close_buffers({ buf })
        end,
      },
      {
        label = "Close Others",
        enabled = found and #others > 0,
        action = function()
          close_buffers(others)
        end,
      },
      {
        label = "Close to the Right",
        enabled = #right > 0,
        action = function()
          close_buffers(right)
        end,
      },
      { separator = true },
      {
        label = "Copy Absolute Path",
        enabled = has_path,
        action = function()
          ProjectPaths.copy({ path })
        end,
      },
      {
        label = "Copy Relative Path",
        enabled = has_path,
        action = function()
          ProjectPaths.copy({ path }, { relative = true })
        end,
      },
    }, mouse, { filetype = "bufferline_context_menu" })
  end)
end

return M
