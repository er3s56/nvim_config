local ActivityBar = require("config.activity_bar")
local BinaryFiles = require("config.binary_files")
local GitPanel = require("config.git_panel")

local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")

local original_cwd = vim.fn.getcwd(0)
local original_columns = vim.o.columns

local function write_bytes(path, bytes)
  local file = assert(io.open(path, "wb"))
  file:write(bytes)
  file:close()
end

local function open(path)
  vim.cmd.edit(vim.fn.fnameescape(path))
  return vim.api.nvim_get_current_buf()
end

local function lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function wait_for(condition, message)
  assert(vim.wait(5000, condition, 50), message)
end

local ok, test_error = pcall(function()
  -- ── a file that can be shown is not touched ───────────────────────────
  -- This is the whole reason the guard is buffer-local: reading a file is
  -- full of things that go quietly wrong -- encodings, line endings, undo --
  -- and nothing here reimplements any of it.
  local plain = root .. "/plain.txt"
  write_bytes(plain, "hello\nworld\n")
  local buf = open(plain)
  assert(vim.deep_equal(lines(buf), { "hello", "world" }), "an ordinary file did not load")
  assert(vim.bo[buf].buftype == "", "an ordinary file lost its buffer type")
  assert(vim.bo[buf].modifiable, "an ordinary file came back read-only")

  local dos = root .. "/dos.txt"
  write_bytes(dos, "one\r\ntwo\r\n")
  buf = open(dos)
  assert(vim.bo[buf].fileformat == "dos", "line endings are no longer detected")
  assert(vim.deep_equal(lines(buf), { "one", "two" }), "a CRLF file did not load")

  -- ── binary by name, without reading it ────────────────────────────────
  local image = root .. "/picture.png"
  write_bytes(image, string.rep("\137PNG\r\n", 400))
  buf = open(image)
  assert(vim.bo[buf].filetype == "binary_placeholder", "a binary file was shown")
  assert(#lines(buf) == 3, "the placeholder is not the three lines it should be")
  assert(lines(buf)[1]:find("picture.png", 1, true), "the placeholder does not name the file")
  assert(lines(buf)[1]:find("binary file", 1, true), "the placeholder does not say why")
  assert(vim.bo[buf].buftype == "nowrite", "the placeholder could be written over the file it stands for")
  assert(not vim.bo[buf].modifiable, "the placeholder is editable")

  -- ── binary by content, whatever it is called ──────────────────────────
  local unnamed = root .. "/mystery"
  write_bytes(unnamed, "text before the\0 first NUL" .. string.rep("x", 100))
  buf = open(unnamed)
  assert(vim.bo[buf].filetype == "binary_placeholder", "a binary file with no extension was shown")

  -- ── and anything past the limit, whatever it holds ────────────────────
  -- A small limit rather than a large file: the size is what is under test,
  -- not the disk.
  BinaryFiles.setup({ limit = 512 })
  local wordy = root .. "/wordy.txt"
  write_bytes(wordy, string.rep("all text, no NUL bytes at all\n", 100))
  buf = open(wordy)
  assert(vim.bo[buf].filetype == "binary_placeholder", "a file past the limit was shown")
  assert(lines(buf)[1]:find("too large", 1, true), "the placeholder blames the wrong thing")

  -- ── opening it anyway ─────────────────────────────────────────────────
  assert(BinaryFiles.open_anyway(buf), "the placeholder would not open the file")
  assert(#lines(buf) == 100, "opening it anyway did not read the file")
  assert(lines(buf)[1] == "all text, no NUL bytes at all", "opening it anyway read the wrong thing")
  assert(vim.bo[buf].buftype == "", "the file stayed unwritable after being opened")
  assert(vim.bo[buf].modifiable, "the file stayed read-only after being opened")
  assert(BinaryFiles.open_anyway(buf) == false, "a file that is already open was opened again")

  -- The placeholder says how, and the keys it names are on it.
  buf = open(image)
  local keys = {}
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    keys[map.lhs] = true
  end
  assert(keys["<CR>"], "the placeholder has no <CR> to open the file with")
  assert(keys["<2-LeftMouse>"], "the placeholder cannot be opened with the mouse")
  assert(lines(buf)[3]:find("anyway", 1, true), "the placeholder does not say it can be opened")
  BinaryFiles.setup()

  -- ── the Git panel's diff does not read one either ─────────────────────
  local function git(args)
    local command = { "git", "-C", root }
    vim.list_extend(command, args)
    local result = vim.system(command, { text = true }):wait()
    assert(result.code == 0, table.concat(args, " ") .. ": " .. (result.stderr or ""))
  end
  git({ "init", "-q" })
  git({ "config", "user.name", "Binary Test" })
  git({ "config", "user.email", "binary@example.invalid" })
  git({ "add", "picture.png" })
  git({ "commit", "-qm", "add the image" })
  write_bytes(image, string.rep("\137PNG\r\n changed", 400))

  vim.cmd.cd(vim.fn.fnameescape(root))
  vim.o.columns = 160
  ActivityBar.setup()
  local view = ActivityBar.open("git", { focus = false })
  wait_for(function()
    return view.content and view.content.kind == "git" and view.content.git_state
  end, "the Git panel did not open")
  local panel = view.content.git_state
  GitPanel.refresh(panel.buf, { status_only = true })

  local row
  wait_for(function()
    for line, entry in pairs(panel.entries or {}) do
      if entry.kind == "worktree_file" and entry.path == "picture.png" then
        row = line
        return true
      end
    end
  end, "the changed image never appeared in the panel")

  vim.api.nvim_set_current_win(panel.win)
  vim.api.nvim_win_set_cursor(panel.win, { row, 0 })
  vim.fn.maparg("<CR>", "n", false, true).callback()
  wait_for(function()
    return panel.preview ~= nil and panel.preview.entry.path == "picture.png"
  end, "the image's diff never opened")

  assert(panel.preview.skipped, "the diff read a binary file after all")
  local shown = vim.api.nvim_buf_get_lines(panel.preview.bufs[2], 0, -1, false)
  assert(#shown == 1 and shown[1]:find("Binary file", 1, true), "the diff shows the file's bytes")
  assert(next(panel.preview.hunk_marks or {}) == nil, "a file that was never read offered hunks to stage")
end)

pcall(BinaryFiles.setup)
pcall(ActivityBar.close)
pcall(GitPanel.close)
vim.o.columns = original_columns
vim.cmd.cd(vim.fn.fnameescape(original_cwd))
vim.fn.delete(root, "rf")
assert(ok, test_error)

print("binary-files-ok")
