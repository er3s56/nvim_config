-- Files that must not be poured into a buffer.
--
-- Neovim reads whatever it is pointed at. A 40MB binary becomes a hundred and
-- sixty thousand lines of mojibake, and the cost is not the read -- half a
-- second -- but everything that then runs over those lines on every redraw.
-- Snacks' bigfile handling turns off highlighting and the language server for
-- files that size, which helps and does not answer it: the lines are still
-- there.
--
-- So decide before the read, not after. `BufAdd` fires when the buffer is
-- created, with the path known and nothing read yet; a buffer that should not
-- be shown gets a BufReadCmd of its own, and every other buffer is left on
-- Neovim's own path, untouched. Nothing here has to reimplement reading a
-- file, which is the part that goes subtly wrong -- encodings, line endings,
-- undo state.

local uv = vim.uv or vim.loop

local M = {}

-- Read this much to decide. git looks at the first 8000 bytes for a NUL and so
-- does everything else that has to answer this question cheaply.
local SNIFF = 8192

-- Anything past this is not shown whatever it holds: the size alone is enough
-- to make opening it a mistake, and it is known without reading a byte.
local DEFAULT_LIMIT = 50 * 1024 * 1024

-- Extensions worth deciding on without reading at all. The list will never be
-- complete, which is what the sniff below is for; it is here so the common
-- cases cost nothing.
local BINARY_EXTENSIONS = {}
for _, extension in ipairs({
  "3gp", "7z", "a", "avi", "avif", "bin", "bmp", "bz2", "class", "dat", "db",
  "deb", "dll", "dmg", "doc", "docx", "dylib", "eot", "exe", "flac", "flv",
  "gif", "gz", "ico", "img", "iso", "jar", "jpeg", "jpg", "keystore", "lz4",
  "lzma", "mkv", "mov", "mp3", "mp4", "mpg", "node", "o", "odp", "ods", "odt",
  "ogg", "otf", "pack", "pdb", "pdf", "pkg", "png", "ppt", "pptx", "psd",
  "pyc", "pyo", "rar", "rlib", "rmeta", "rpm", "so", "sqlite", "sqlite3",
  "svgz", "tar", "tbz2", "tgz", "tiff", "ttf", "wasm", "wav", "webm", "webp",
  "woff", "woff2", "xls", "xlsx", "xz", "zip", "zst",
}) do
  BINARY_EXTENSIONS[extension] = true
end

local guards = {}
local limit = DEFAULT_LIMIT

local function human(size)
  local units = { "B", "KB", "MB", "GB", "TB" }
  local value, unit = size, 1
  while value >= 1024 and unit < #units do
    value, unit = value / 1024, unit + 1
  end
  if unit == 1 then
    return ("%d B"):format(value)
  end
  return ("%.1f %s"):format(value, units[unit])
end

local function looks_binary(path)
  local file = io.open(path, "rb")
  if not file then
    return false
  end
  local head = file:read(SNIFF)
  file:close()
  return head ~= nil and head:find("\0", 1, true) ~= nil
end

--- Why this path must not be shown, or nil when it can be. A diff pane holds
--- what it is given in memory and side by side, so it passes a smaller limit
--- than a buffer does.
---@return "binary"|"large"|nil reason, table|nil stat
function M.reason(path, opts)
  if path == nil or path == "" or path:find("://", 1, true) then
    return nil
  end
  local stat = uv.fs_stat(path)
  if not stat or stat.type ~= "file" or stat.size == 0 then
    return nil
  end
  if BINARY_EXTENSIONS[path:lower():match("%.([%w]+)$") or ""] then
    return "binary", stat
  end
  if stat.size > ((opts and opts.limit) or limit) then
    return "large", stat
  end
  if looks_binary(path) then
    return "binary", stat
  end
  return nil
end

local function describe(path, stat, reason)
  local size = human(stat and stat.size or 0)
  if reason == "large" then
    return ("%s · %s · too large to show"):format(vim.fn.fnamemodify(path, ":t"), size)
  end
  return ("%s · %s · binary file, not shown"):format(vim.fn.fnamemodify(path, ":t"), size)
end

--- Read the file after all, into the buffer that is standing in for it.
function M.open_anyway(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local guard = guards[buf]
  if not guard then
    return false
  end
  -- The guard is the buffer's own BufReadCmd. Take it away before reading, or
  -- the read it is about to do lands right back on this placeholder.
  pcall(vim.api.nvim_del_autocmd, guard.autocmd)
  guards[buf] = nil
  vim.bo[buf].modifiable = true
  vim.bo[buf].buftype = ""
  vim.b[buf].binary_placeholder = nil
  vim.api.nvim_buf_call(buf, function()
    -- `noautocmd` so nothing -- including the guard's own kind -- intercepts
    -- this one; the file is read exactly the way Neovim reads any other.
    vim.cmd("noautocmd edit!")
    vim.cmd("filetype detect")
  end)
  return true
end

local function place(buf, path, stat, reason)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    describe(path, stat, reason),
    "",
    "Press <CR>, or double click, to open it anyway.",
  })
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  -- `nowrite` rather than `nofile`: the buffer still stands for a real path,
  -- and writing three lines of explanation over the file it names would be a
  -- catastrophe of its own.
  vim.bo[buf].buftype = "nowrite"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "binary_placeholder"
  vim.b[buf].binary_placeholder = { path = path, reason = reason, size = stat and stat.size or 0 }

  for _, lhs in ipairs({ "<CR>", "<2-LeftMouse>" }) do
    vim.keymap.set("n", lhs, function()
      M.open_anyway(buf)
    end, { buffer = buf, silent = true, desc = "Open this file anyway" })
  end
end

function M.setup(opts)
  opts = opts or {}
  limit = opts.limit or DEFAULT_LIMIT
  local group = vim.api.nvim_create_augroup("project_binary_files", { clear = true })

  vim.api.nvim_create_autocmd("BufAdd", {
    group = group,
    callback = function(event)
      local buf = event.buf
      if guards[buf] or vim.b[buf].binary_allow then
        return
      end
      local path = vim.api.nvim_buf_get_name(buf)
      local reason, stat = M.reason(path)
      if not reason then
        return
      end
      -- Buffer-local, so a file that can be shown never meets this at all and
      -- keeps Neovim's own read path.
      guards[buf] = {
        autocmd = vim.api.nvim_create_autocmd("BufReadCmd", {
          group = group,
          buffer = buf,
          callback = function()
            place(buf, path, uv.fs_stat(path) or stat, reason)
          end,
        }),
      }
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(event)
      guards[event.buf] = nil
    end,
  })
end

M.human = human

return M
