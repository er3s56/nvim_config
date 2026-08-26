local M = {}

local active_menu
local handlers = {}
local handler_order = {}
local setup_done = false
local disabled_namespace = vim.api.nvim_create_namespace("project_context_menu_disabled")

local function report_handler_error(name, err)
  vim.schedule(function()
    local message = ("Context menu handler `%s` failed: %s"):format(name, tostring(err))
    if rawget(_G, "Snacks") and Snacks.notify then
      Snacks.notify.error(message)
    else
      vim.notify(message, vim.log.levels.ERROR)
    end
  end)
end

function M.close()
  local menu = active_menu
  active_menu = nil
  if menu and menu.win and vim.api.nvim_win_is_valid(menu.win) then
    vim.api.nvim_win_close(menu.win, true)
  end
  if menu and menu.buf and vim.api.nvim_buf_is_valid(menu.buf) then
    vim.api.nvim_buf_delete(menu.buf, { force = true })
  end
end

function M.open(entries, mouse, opts)
  M.close()
  if not entries or #entries == 0 then
    return
  end
  opts = opts or {}

  local lines, width = {}, 1
  for _, entry in ipairs(entries) do
    local line = entry.separator and string.rep("─", 8) or "  " .. entry.label
    lines[#lines + 1] = line
    width = math.max(width, vim.api.nvim_strwidth(line))
  end
  width = math.min(math.max(width + 2, opts.min_width or 24), math.max(10, vim.o.columns - 4))
  for index, entry in ipairs(entries) do
    if entry.separator then
      lines[index] = string.rep("─", width)
    end
  end

  local height = #lines
  local row = math.max(0, math.min(mouse.screenrow - 1, vim.o.lines - height - 3))
  local col = math.max(0, math.min(mouse.screencol - 1, vim.o.columns - width - 2))
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = opts.filetype or "context_menu"

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    focusable = true,
    zindex = opts.zindex or 250,
  })
  vim.wo[win].cursorline = true
  vim.wo[win].winhighlight = opts.winhighlight or "Normal:NormalFloat,FloatBorder:FloatBorder,CursorLine:PmenuSel"
  vim.wo[win].wrap = false

  active_menu = { buf = buf, win = win, entries = entries }
  for index, entry in ipairs(entries) do
    if entry.separator or entry.enabled == false then
      vim.api.nvim_buf_add_highlight(buf, disabled_namespace, "Comment", index - 1, 0, -1)
    end
  end

  local function selectable(index)
    local entry = entries[index]
    return entry and not entry.separator and entry.enabled ~= false and type(entry.action) == "function"
  end

  local function seek(direction)
    local current = vim.api.nvim_win_get_cursor(win)[1]
    for step = 1, #entries do
      local index = (current - 1 + direction * step) % #entries + 1
      if selectable(index) then
        vim.api.nvim_win_set_cursor(win, { index, 0 })
        return
      end
    end
  end

  local function activate(index)
    index = index or vim.api.nvim_win_get_cursor(win)[1]
    local entry = entries[index]
    if not selectable(index) then
      return
    end
    M.close()
    vim.schedule(entry.action)
  end

  for index = 1, #entries do
    if selectable(index) then
      vim.api.nvim_win_set_cursor(win, { index, 0 })
      break
    end
  end

  local map_opts = { buffer = buf, silent = true, nowait = true }
  local function map_many(lhs, rhs, map_options)
    for _, key in ipairs(lhs) do
      vim.keymap.set("n", key, rhs, map_options or map_opts)
    end
  end
  map_many({ "j", "<Down>", "<Tab>" }, function()
    seek(1)
  end)
  map_many({ "k", "<Up>", "<S-Tab>" }, function()
    seek(-1)
  end)
  map_many({ "<CR>", "<Space>" }, function()
    activate()
  end)
  map_many({ "q", "<Esc>" }, M.close)
  map_many({ "<LeftMouse>", "<RightMouse>" }, function()
    local position = vim.fn.getmousepos()
    if position.winid == win and position.line >= 1 and position.line <= #entries then
      vim.schedule(function()
        if active_menu and active_menu.win == win and vim.api.nvim_win_is_valid(win) then
          vim.api.nvim_win_set_cursor(win, { position.line, 0 })
          activate(position.line)
        end
      end)
    else
      vim.schedule(M.close)
    end
    return ""
  end, vim.tbl_extend("force", map_opts, { expr = true }))
  map_many({ "<LeftRelease>", "<RightRelease>" }, "<Nop>")

  vim.api.nvim_create_autocmd("WinLeave", {
    once = true,
    buffer = buf,
    callback = function()
      vim.schedule(function()
        if active_menu and active_menu.buf == buf then
          M.close()
        end
      end)
    end,
  })
end

function M.register(name, handler)
  vim.validate("name", name, "string")
  vim.validate("handler", handler, "function")
  if not handlers[name] then
    handler_order[#handler_order + 1] = name
  end
  handlers[name] = handler
end

function M.setup()
  if setup_done then
    return
  end
  setup_done = true
  vim.keymap.set({ "n", "x", "i", "t" }, "<RightMouse>", function()
    local mouse = vim.fn.getmousepos()
    for _, name in ipairs(handler_order) do
      local ok, handled = pcall(handlers[name], mouse)
      if not ok then
        report_handler_error(name, handled)
      elseif handled then
        return ""
      end
    end
    return "<RightMouse>"
  end, {
    expr = true,
    replace_keycodes = true,
    silent = true,
    desc = "Open project context menu",
  })
end

M._handlers = handlers

return M
