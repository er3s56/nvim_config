local ActivityBar = require("config.activity_bar")
local original_columns = vim.o.columns
local original_error = vim.v.errmsg
vim.o.columns = 160

local ok, err = xpcall(function()
  for _, view in ipairs({ "explorer", "search" }) do
    local state = ActivityBar.open(view, { focus = false })
    assert(
      vim.wait(5000, function()
        local picker = state.content and state.content.picker
        return picker and picker.list.win:valid() and not picker:is_active()
      end),
      view .. " did not become ready"
    )
    local list_window = state.content.picker.list.win
    -- WinClosed makes Snacks defer its augroup cleanup, but clears win.win
    -- immediately. A resize in that gap must not run the dead list callback.
    vim.api.nvim_win_close(list_window.win, true)
    vim.v.errmsg = ""
    local resized, resize_error = pcall(vim.api.nvim_exec_autocmds, "VimResized", {})
    assert(resized and vim.v.errmsg == "", tostring(resize_error) .. vim.v.errmsg)
    ActivityBar.close()
    vim.wait(300)
  end
end, debug.traceback)

pcall(ActivityBar.close)
vim.wait(300)
vim.o.columns = original_columns
vim.v.errmsg = original_error
assert(ok, err)
print("activity-bar-resize-teardown-ok")
