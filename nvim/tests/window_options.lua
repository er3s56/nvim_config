local ActivityBar = require("config.activity_bar")
local GitPanel = require("config.git_panel")

local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")

local function git(args)
  local command = { "git", "-C", root }
  vim.list_extend(command, args)
  local result = vim.system(command, { text = true }):wait()
  assert(result.code == 0, table.concat(args, " ") .. ": " .. (result.stderr or ""))
end

local original_cwd = vim.fn.getcwd(0)
local original_columns = vim.o.columns

-- Every window option this configuration sets on a window of its own. Each is
-- window-local, so setting one must leave the value new windows start from
-- exactly where it was.
local WINDOW_OPTIONS = {
  "cursorbind", "cursorline", "foldcolumn", "foldenable", "list", "number",
  "relativenumber", "scrollbind", "signcolumn", "statuscolumn", "winbar",
  "winfixbuf", "winfixheight", "winfixwidth", "winhighlight", "wrap",
}

local function global_defaults()
  local values = {}
  for _, name in ipairs(WINDOW_OPTIONS) do
    values[name] = vim.api.nvim_get_option_value(name, { scope = "global" })
  end
  return values
end

local function wait_for(condition, message)
  assert(vim.wait(5000, condition, 50), message)
end

local ok, test_error = pcall(function()
  vim.fn.writefile({ "int a = 1;", "int b = 2;" }, root .. "/tracked.c")
  vim.fn.writefile({ "int elsewhere = 3;" }, root .. "/other.c")
  git({ "init", "-q" })
  git({ "config", "user.name", "Window Options Test" })
  git({ "config", "user.email", "window-options@example.invalid" })
  git({ "add", "." })
  git({ "commit", "-qm", "the first commit" })
  vim.fn.writefile({ "int a = 1;", "int b = 22;" }, root .. "/tracked.c")

  vim.cmd.cd(vim.fn.fnameescape(root))
  vim.o.columns = 160

  -- ── a panel decides nothing for windows that are not its own ──────────
  -- `vim.wo[win].number = false` reads as `:setlocal` and is documented as
  -- one, but for the current window Neovim carries it to the global value as
  -- well: the sidebar switching off its own line numbers was switching them
  -- off for every window opened afterwards.
  local before = global_defaults()
  ActivityBar.setup()
  ActivityBar.open("explorer", { focus = true })
  local view = ActivityBar.open("git", { focus = true })
  wait_for(function()
    return view.content and view.content.kind == "git" and view.content.git_state
  end, "the Git panel did not open")
  local panel = view.content.git_state
  GitPanel.refresh(panel.buf, { status_only = true })
  wait_for(function()
    return panel.changes ~= nil
  end, "the panel never read the repository")

  local after = global_defaults()
  for _, name in ipairs(WINDOW_OPTIONS) do
    assert(
      vim.deep_equal(before[name], after[name]),
      ("opening the panels changed what new windows start with: %s went from %s to %s"):format(
        name, vim.inspect(before[name]), vim.inspect(after[name])
      )
    )
  end

end)

pcall(ActivityBar.close)
pcall(GitPanel.close)
vim.o.columns = original_columns
vim.cmd.cd(vim.fn.fnameescape(original_cwd))
vim.fn.delete(root, "rf")
assert(ok, test_error)

print("window-options-ok")
