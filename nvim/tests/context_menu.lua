local ContextMenu = require("config.context_menu")

local calls = {}
ContextMenu.register("test_miss", function(mouse)
  calls[#calls + 1] = { name = "miss", mouse = mouse }
  return false
end)
ContextMenu.register("test_hit", function(mouse)
  calls[#calls + 1] = { name = "hit", mouse = mouse }
  return true
end)
ContextMenu.setup()

local mapping = vim.fn.maparg("<RightMouse>", "n", false, true)
assert(type(mapping.callback) == "function", "shared right-click dispatcher is not registered")
assert(mapping.callback() == "", "a matching context handler did not consume right click")
assert(calls[1].name == "miss" and calls[2].name == "hit", "context handlers did not run in registration order")

ContextMenu.register("test_hit", function()
  return false
end)
assert(mapping.callback() == "<RightMouse>", "unhandled right click no longer passes through to Neovim")

local activated = false
ContextMenu.open({
  { label = "disabled", enabled = false, action = function() end },
  { separator = true },
  {
    label = "enabled",
    action = function()
      activated = true
    end,
  },
}, { screenrow = 1, screencol = 1 }, { filetype = "test_context_menu" })
assert(vim.bo.filetype == "test_context_menu", "shared context float did not use the requested filetype")
assert(vim.api.nvim_win_get_cursor(0)[1] == 3, "context menu did not focus the first enabled entry")

local activate = vim.fn.maparg("<CR>", "n", false, true)
assert(type(activate.callback) == "function", "context menu activation mapping is missing")
activate.callback()
assert(
  vim.wait(1000, function()
    return activated
  end),
  "context menu action did not run"
)
ContextMenu.close()

print("context-menu-ok")
