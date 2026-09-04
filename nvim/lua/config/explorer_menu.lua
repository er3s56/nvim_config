local uv = vim.uv or vim.loop

local FileOps = require("config.explorer_file_ops")
local Platform = require("config.explorer_platform")
local ContextMenu = require("config.context_menu")
local Pinned = require("config.pinned")

local M = {}

local setup_done = false

local function notify(message, level)
  if rawget(_G, "Snacks") and Snacks.notify then
    Snacks.notify(message, { level = level })
  else
    vim.notify(message, level)
  end
end

local function error_message(message)
  notify(message, vim.log.levels.ERROR)
end

local function warn(message)
  notify(message, vim.log.levels.WARN)
end

local function info(message)
  notify(message, vim.log.levels.INFO)
end

local function valid_picker(picker)
  return picker
    and not picker.closed
    and picker.list
    and picker.list.win
    and picker.list.win.win
    and vim.api.nvim_win_is_valid(picker.list.win.win)
end

local function stop_current_mode()
  local mode = vim.api.nvim_get_mode().mode
  if mode == "v" or mode == "V" or mode == "\22" then
    vim.cmd("normal! \027")
  elseif mode:sub(1, 1) == "i" or mode:sub(1, 1) == "t" then
    vim.cmd.stopinsert()
  end
end

local function explorer_at_mouse(mouse)
  if not (rawget(_G, "Snacks") and Snacks.picker and mouse and mouse.winid and mouse.winid > 0) then
    return
  end
  for _, picker in ipairs(Snacks.picker.get({ source = "explorer" })) do
    if valid_picker(picker) and picker.list.win.win == mouse.winid then
      return picker
    end
  end
end

local function mouse_item(picker, mouse)
  if mouse.line < 1 then
    return
  end
  local position = vim.fn.screenpos(mouse.winid, mouse.line, 1)
  if position.row == 0 or position.row ~= mouse.screenrow then
    return
  end
  local view = vim.api.nvim_win_call(mouse.winid, vim.fn.winsaveview)
  local row = mouse.line - view.topline + 1
  if row < 1 or row > vim.api.nvim_win_get_height(mouse.winid) then
    return
  end
  local index = picker.list:row2idx(row)
  if index < 1 or index > picker.list:count() then
    return
  end
  return picker.list:get(index), index
end

local function item_path(item)
  return item and item.file and vim.fs.normalize(item.file) or nil
end

local function selected_paths(picker, item, was_selected)
  if not item then
    return {}
  end
  if was_selected then
    local paths = {}
    for _, selected in ipairs(picker:selected()) do
      local path = item_path(selected)
      if path then
        paths[#paths + 1] = path
      end
    end
    if #paths > 0 then
      return paths
    end
  end
  return { item.file }
end

local function context_at_mouse(picker, mouse)
  stop_current_mode()
  vim.api.nvim_set_current_win(mouse.winid)

  local item, index = mouse_item(picker, mouse)
  local was_selected = item and picker.list:is_selected(item) or false
  if item then
    picker.list:view(index)
    if not was_selected then
      picker.list:set_selected()
    end
  else
    picker.list:set_selected()
  end

  local path = item_path(item)
  local target_dir = not path and picker:cwd() or item.dir and path or vim.fs.dirname(path)
  return {
    picker = picker,
    item = item,
    paths = selected_paths(picker, item, was_selected),
    target_dir = vim.fs.normalize(target_dir),
    mouse = mouse,
  }
end

local function refresh(picker, target, dirs)
  if not valid_picker(picker) then
    return
  end
  local Tree = require("snacks.explorer.tree")
  for _, dir in ipairs(dirs or { target or picker:cwd() }) do
    Tree:refresh(dir)
  end
  if target then
    Tree:open(vim.fn.isdirectory(target) == 1 and target or vim.fs.dirname(target))
  end
  require("snacks.explorer.actions").update(picker, { target = target, refresh = true })
  -- Creating, renaming and deleting files changes what Git reports, but none
  -- of it writes a buffer, touches the Git directory, or takes focus out of
  -- Neovim, so no other refresh trigger sees it.
  require("config.git_panel").refresh_all()
end

local function confirm(prompt, callback)
  Snacks.picker.util.confirm(prompt, callback)
end

local function input_name(prompt, callback)
  Snacks.input({ prompt = prompt }, function(value)
    if value and not value:find("^%s*$") then
      callback(value)
    end
  end)
end

local function is_inside(path, parent)
  path = vim.fs.normalize(path):gsub("/$", "")
  parent = vim.fs.normalize(parent):gsub("/$", "")
  if vim.fn.has("win32") == 1 then
    path, parent = path:lower(), parent:lower()
  end
  return path:sub(1, #parent + 1) == parent .. "/"
end

local function create_entry(ctx, directory)
  input_name(directory and "New Folder" or "New File", function(value)
    local target = vim.fs.normalize(vim.fs.joinpath(ctx.target_dir, value))
    if not is_inside(target, ctx.target_dir) then
      warn("New entries must stay inside the target directory")
      return
    end
    if uv.fs_lstat(target) then
      warn(("Already exists: `%s`"):format(target))
      return
    end

    if directory then
      if vim.fn.mkdir(target, "p") == 0 and not uv.fs_stat(target) then
        error_message(("Failed to create folder: `%s`"):format(target))
        return
      end
    else
      local parent = vim.fs.dirname(target)
      if vim.fn.mkdir(parent, "p") == 0 and not uv.fs_stat(parent) then
        error_message(("Failed to create parent folder: `%s`"):format(parent))
        return
      end
      local fd, err = uv.fs_open(target, "wx", 420)
      if not fd then
        error_message(("Failed to create file: `%s`\n%s"):format(target, err or "unknown error"))
        return
      end
      uv.fs_close(fd)
    end
    refresh(ctx.picker, target, { ctx.target_dir })
  end)
end

local function copy_files(ctx)
  local ok, err = Platform.copy_files(ctx.paths)
  if not ok then
    error_message("Failed to write files to the system clipboard:\n" .. (err or "unknown error"))
    return
  end
  info(("Copied %d filesystem item(s)"):format(#ctx.paths))
end

local function perform_paste(ctx, plan, overwrite)
  local ok, err = FileOps.execute(plan, { overwrite = overwrite })
  if not ok then
    error_message("Paste failed:\n" .. (err or "unknown error"))
    return
  end
  refresh(ctx.picker, plan.destination, { plan.destination })
  info(("Pasted %d filesystem item(s)"):format(#plan.entries))
end

local function paste_files(ctx)
  local paths, read_err = Platform.read_files()
  if not paths then
    error_message("Failed to read the system file clipboard:\n" .. (read_err or "unknown error"))
    return
  end
  local existing, seen = {}, {}
  for _, path in ipairs(paths) do
    path = vim.fs.normalize(path)
    if uv.fs_lstat(path) and not seen[path] then
      seen[path] = true
      existing[#existing + 1] = path
    end
  end
  if #existing == 0 then
    warn("No files or folders found in the system clipboard")
    return
  end

  local plan, plan_err = FileOps.plan(existing, ctx.target_dir)
  if not plan then
    warn("Cannot paste:\n" .. (plan_err or "unknown error"))
    return
  end
  if #plan.conflicts == 0 then
    perform_paste(ctx, plan, false)
    return
  end

  local preview = {}
  for index = 1, math.min(3, #plan.conflicts) do
    preview[#preview + 1] = vim.fs.basename(plan.conflicts[index])
  end
  local suffix = #plan.conflicts > #preview and (" and %d more"):format(#plan.conflicts - #preview) or ""
  confirm(
    ("Destination already contains %s%s. Merge folders and overwrite conflicting items?"):format(
      table.concat(preview, ", "),
      suffix
    ),
    function()
      perform_paste(ctx, plan, true)
    end
  )
end

local function copy_text(paths, label)
  local ok, err = pcall(vim.fn.setreg, "+", table.concat(paths, "\n"), "l")
  if not ok then
    error_message(("Failed to copy %s:\n%s"):format(label, err or "unknown error"))
    return
  end
  info(("Copied %s"):format(label))
end

local function project_root(picker)
  if rawget(_G, "LazyVim") and LazyVim.root then
    local ok, root = pcall(LazyVim.root)
    if ok and root then
      return vim.fs.normalize(root)
    end
  end
  return vim.fs.normalize(picker:cwd())
end

local function relative_paths(ctx)
  local root = project_root(ctx.picker)
  local paths = {}
  for _, path in ipairs(ctx.paths) do
    paths[#paths + 1] = vim.fs.relpath(root, path) or path
  end
  copy_text(paths, "project-relative path")
end

local function open_item(ctx)
  if not (ctx.item and valid_picker(ctx.picker)) then
    return
  end
  ctx.picker.list:set_selected()
  require("snacks.explorer.actions").actions.confirm(ctx.picker, ctx.item, { cmd = "edit" })
end

local function reveal_item(ctx)
  local path = ctx.item and ctx.item.file or ctx.target_dir
  local ok, message = Platform.reveal(path)
  if not ok then
    error_message("Failed to reveal in the system file manager:\n" .. (message or "unknown error"))
  elseif message then
    warn(message)
  end
end

local function rename_item(ctx)
  if ctx.item and valid_picker(ctx.picker) then
    ctx.picker.list:set_selected()
    require("snacks.explorer.actions").actions.explorer_rename(ctx.picker, ctx.item)
  end
end

local function remove_buffers(paths)
  for _, path in ipairs(paths) do
    Snacks.bufdelete({ file = path, force = true })
  end
end

local function refresh_deleted(ctx, paths)
  local dirs, seen = {}, {}
  for _, path in ipairs(paths) do
    local dir = vim.fs.dirname(path)
    if not seen[dir] then
      seen[dir] = true
      dirs[#dirs + 1] = dir
    end
  end
  if valid_picker(ctx.picker) then
    ctx.picker.list:set_selected()
    refresh(ctx.picker, nil, dirs)
  end
end

local function permanently_delete(ctx, paths)
  local failed, deleted = {}, {}
  for _, path in ipairs(paths) do
    if uv.fs_lstat(path) then
      local result = vim.fn.delete(path, "rf")
      if result == 0 then
        deleted[#deleted + 1] = path
      else
        failed[#failed + 1] = path
      end
    end
  end
  remove_buffers(deleted)
  refresh_deleted(ctx, deleted)
  if #failed > 0 then
    error_message(("Permanent deletion failed:\n%s"):format(table.concat(failed, "\n")))
  elseif #deleted > 0 then
    warn(("Permanently deleted %d item(s)"):format(#deleted))
  end
end

local function delete_items(ctx)
  local what = #ctx.paths == 1 and vim.fs.basename(ctx.paths[1]) or ("%d items"):format(#ctx.paths)
  confirm(("Move %s to the system trash?"):format(what), function()
    local trashed, failed, errors = {}, {}, {}
    if Platform.trash_available() then
      for _, path in ipairs(ctx.paths) do
        local ok, err = Platform.trash(path)
        if ok then
          trashed[#trashed + 1] = path
        else
          failed[#failed + 1] = path
          errors[#errors + 1] = ("%s: %s"):format(path, err or "unknown error")
        end
      end
    else
      vim.list_extend(failed, ctx.paths)
      errors[1] = "No system trash backend is available"
    end

    remove_buffers(trashed)
    refresh_deleted(ctx, trashed)
    if #failed == 0 then
      info(("Moved %d item(s) to the system trash"):format(#trashed))
      return
    end

    warn("Some items could not be moved to the system trash:\n" .. table.concat(errors, "\n"))
    local failed_what = #failed == 1 and vim.fs.basename(failed[1]) or ("%d items"):format(#failed)
    confirm(("Trash unavailable. Permanently delete %s? This cannot be undone."):format(failed_what), function()
      permanently_delete(ctx, failed)
    end)
  end)
end

local function all_pinned(ctx)
  local root = project_root(ctx.picker)
  for _, path in ipairs(ctx.paths) do
    if not Pinned.is_pinned(root, path) then
      return false
    end
  end
  return #ctx.paths > 0
end

local function pinned_label(ctx)
  if all_pinned(ctx) then
    return #ctx.paths > 1 and "Unpin These" or "Unpin"
  end
  return #ctx.paths > 1 and "Pin These" or "Pin"
end

local function toggle_pins(ctx)
  local root = project_root(ctx.picker)
  local unpinning = all_pinned(ctx)
  for _, path in ipairs(ctx.paths) do
    if unpinning then
      Pinned.remove(root, path)
    else
      Pinned.add(root, path)
    end
  end
  info((unpinning and "Unpinned " or "Pinned ") .. #ctx.paths .. " path(s)")
end

local function entries_for(ctx)
  local has_item = ctx.item ~= nil
  local has_paths = #ctx.paths > 0
  return {
    {
      label = "Open",
      enabled = has_item,
      action = function()
        open_item(ctx)
      end,
    },
    {
      label = "Reveal in File Manager",
      action = function()
        reveal_item(ctx)
      end,
    },
    {
      -- Whole selections at once: pinning six driver directories one right
      -- click at a time is the tedium this is meant to remove.
      label = pinned_label(ctx),
      enabled = has_paths,
      action = function()
        toggle_pins(ctx)
      end,
    },
    { separator = true },
    {
      label = "New File",
      action = function()
        create_entry(ctx, false)
      end,
    },
    {
      label = "New Folder",
      action = function()
        create_entry(ctx, true)
      end,
    },
    { separator = true },
    {
      label = "Copy",
      enabled = has_paths,
      action = function()
        copy_files(ctx)
      end,
    },
    {
      label = "Paste",
      action = function()
        paste_files(ctx)
      end,
    },
    {
      label = "Copy Absolute Path",
      enabled = has_paths,
      action = function()
        copy_text(ctx.paths, "absolute path")
      end,
    },
    {
      label = "Copy Relative Path",
      enabled = has_paths,
      action = function()
        relative_paths(ctx)
      end,
    },
    { separator = true },
    {
      label = "Rename",
      enabled = has_item,
      action = function()
        rename_item(ctx)
      end,
    },
    {
      label = "Delete",
      enabled = has_paths,
      action = function()
        delete_items(ctx)
      end,
    },
    {
      label = "Refresh",
      action = function()
        refresh(ctx.picker, ctx.item and ctx.item.file or nil, { ctx.target_dir })
      end,
    },
  }
end

local function show_context(picker, mouse)
  if not valid_picker(picker) then
    return
  end
  local ctx = context_at_mouse(picker, mouse)
  ContextMenu.open(entries_for(ctx), mouse, { filetype = "explorer_context_menu" })
end

function M.setup()
  if setup_done then
    return
  end
  setup_done = true
  ContextMenu.setup()
  ContextMenu.register("explorer", function(mouse)
    local picker = explorer_at_mouse(mouse)
    if picker then
      vim.schedule(function()
        show_context(picker, mouse)
      end)
      return true
    end
  end)
end

M._context_at_mouse = context_at_mouse
M._entries_for = entries_for
M._open = function(entries, mouse)
  ContextMenu.open(entries, mouse, { filetype = "explorer_context_menu" })
end
M._close = ContextMenu.close

return M
