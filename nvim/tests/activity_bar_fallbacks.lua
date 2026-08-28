local ActivityBar = require("config.activity_bar")

local original_cwd = vim.fn.getcwd(0)
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")

local original_executable = vim.fn.executable
local ok, test_error = pcall(function()
  vim.cmd.cd(vim.fn.fnameescape(root))
  ActivityBar.setup()
  ActivityBar.open("git", { focus = false })
  assert(
    vim.wait(1000, function()
      local state = ActivityBar.current()
      return state and state.content and state.content.kind == "git" and ActivityBar._content_root(state.content)
    end),
    "non-Git fallback sidebar did not open"
  )
  local state = ActivityBar.current()
  assert(not state.content.git_state, "non-Git project created a live Git model")
  local git_buf = vim.api.nvim_win_get_buf(ActivityBar._content_root(state.content))
  assert(
    table.concat(vim.api.nvim_buf_get_lines(git_buf, 0, -1, false), " "):find("not a Git repository", 1, true),
    "non-Git sidebar has no explicit empty state"
  )

  vim.fn.executable = function(command)
    return command == "rg" and 0 or original_executable(command)
  end
  ActivityBar.open("search", { focus = false })
  assert(
    vim.wait(1000, function()
      local current = ActivityBar.current()
      return current
        and current.content
        and current.content.kind == "search"
        and ActivityBar._content_root(current.content)
    end),
    "missing-rg fallback sidebar did not open"
  )
  state = ActivityBar.current()
  assert(not state.content.picker, "missing rg still created a Search picker")
  local search_buf = vim.api.nvim_win_get_buf(ActivityBar._content_root(state.content))
  assert(
    table.concat(vim.api.nvim_buf_get_lines(search_buf, 0, -1, false), " "):find("was not found", 1, true),
    "missing-rg sidebar has no explicit error state"
  )
end)

vim.fn.executable = original_executable
pcall(ActivityBar.close)
vim.cmd.cd(vim.fn.fnameescape(original_cwd))
vim.fn.delete(root, "rf")
assert(ok, test_error)

print("activity-bar-fallbacks-ok")
