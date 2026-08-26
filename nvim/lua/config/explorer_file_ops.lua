local uv = vim.uv or vim.loop

local M = {}

local function normalize(path)
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  return path == "/" and path or path:gsub("/$", "")
end

local function path_key(path)
  path = normalize(path)
  if vim.fn.has("win32") == 1 then
    path = path:lower()
  end
  return path
end

local function is_same_or_child(path, parent)
  path, parent = path_key(path), path_key(parent)
  return path == parent or path:sub(1, #parent + 1) == parent .. "/"
end

local function scandir(path)
  local handle, err = uv.fs_scandir(path)
  if not handle then
    return nil, err
  end
  local entries = {}
  while true do
    local name = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    entries[#entries + 1] = name
  end
  table.sort(entries)
  return entries
end

local function add_conflict(plan, path)
  local key = path_key(path)
  if not plan.conflict_map[key] then
    plan.conflict_map[key] = true
    plan.conflicts[#plan.conflicts + 1] = path
  end
end

local function inspect_path(plan, from, to)
  local source, err = uv.fs_lstat(from)
  if not source then
    return nil, ("Source does not exist: `%s`%s"):format(from, err and "\n" .. err or "")
  end

  local destination = uv.fs_lstat(to)
  if destination then
    add_conflict(plan, to)
  end

  if source.type == "directory" and destination and destination.type == "directory" then
    local entries, scan_err = scandir(from)
    if not entries then
      return nil, ("Cannot read directory `%s`:\n%s"):format(from, scan_err or "unknown error")
    end
    for _, name in ipairs(entries) do
      local ok, child_err = inspect_path(plan, vim.fs.joinpath(from, name), vim.fs.joinpath(to, name))
      if not ok then
        return nil, child_err
      end
    end
  end
  return true
end

---@class config.explorer.CopyPlan
---@field destination string
---@field entries {from:string,to:string}[]
---@field conflicts string[]
---@field conflict_map table<string, boolean>

---Build a copy plan without changing the filesystem.
---@param paths string[]
---@param destination string
---@return config.explorer.CopyPlan? plan
---@return string? error
function M.plan(paths, destination)
  destination = normalize(destination)
  local destination_stat = uv.fs_stat(destination)
  if not destination_stat or destination_stat.type ~= "directory" then
    return nil, ("Paste target is not a directory: `%s`"):format(destination)
  end
  local destination_real = uv.fs_realpath(destination) or destination
  local plan = {
    destination = destination,
    entries = {},
    conflicts = {},
    conflict_map = {},
  }
  local destinations = {}

  for _, raw_path in ipairs(paths) do
    local from = normalize(raw_path)
    local source = uv.fs_lstat(from)
    if not source then
      return nil, ("Clipboard source no longer exists: `%s`"):format(from)
    end
    local name = vim.fs.basename(from)
    if not name or name == "" then
      return nil, ("Cannot copy filesystem root: `%s`"):format(from)
    end
    local to = vim.fs.joinpath(destination, name)
    local from_real = uv.fs_realpath(from) or from
    local to_real = uv.fs_realpath(to) or vim.fs.joinpath(destination_real, name)
    if path_key(from_real) == path_key(to_real) then
      return nil, ("Cannot paste an item into its current directory: `%s`"):format(from)
    end
    if source.type == "directory" and is_same_or_child(to_real, from_real) then
      return nil, ("Cannot copy a directory into itself or one of its descendants: `%s`"):format(from)
    end

    local destination_key = path_key(to)
    if destinations[destination_key] then
      add_conflict(plan, to)
    end
    destinations[destination_key] = true
    plan.entries[#plan.entries + 1] = { from = from, to = to }

    local ok, err = inspect_path(plan, from, to)
    if not ok then
      return nil, err
    end
  end

  return plan
end

local function remove_path(path)
  local result = vim.fn.delete(path, "rf")
  if result ~= 0 then
    return nil, ("Failed to replace `%s`"):format(path)
  end
  return true
end

local function copy_path(from, to, overwrite)
  local source, stat_err = uv.fs_lstat(from)
  if not source then
    return nil, ("Cannot read `%s`:\n%s"):format(from, stat_err or "unknown error")
  end
  local destination = uv.fs_lstat(to)

  if source.type == "directory" then
    if destination and destination.type ~= "directory" then
      if not overwrite then
        return nil, ("Destination already exists: `%s`"):format(to)
      end
      local ok, err = remove_path(to)
      if not ok then
        return nil, err
      end
      destination = nil
    end
    if not destination then
      local ok, err = uv.fs_mkdir(to, source.mode or 493)
      if not ok and not uv.fs_stat(to) then
        return nil, ("Cannot create directory `%s`:\n%s"):format(to, err or "unknown error")
      end
    elseif not overwrite then
      return nil, ("Destination already exists: `%s`"):format(to)
    end

    local entries, scan_err = scandir(from)
    if not entries then
      return nil, ("Cannot read directory `%s`:\n%s"):format(from, scan_err or "unknown error")
    end
    for _, name in ipairs(entries) do
      local ok, err = copy_path(vim.fs.joinpath(from, name), vim.fs.joinpath(to, name), overwrite)
      if not ok then
        return nil, err
      end
    end
    return true
  end

  if source.type ~= "file" and source.type ~= "link" then
    return nil, ("Unsupported filesystem entry `%s` (%s)"):format(from, source.type or "unknown")
  end
  if destination then
    if not overwrite then
      return nil, ("Destination already exists: `%s`"):format(to)
    end
    local ok, err = remove_path(to)
    if not ok then
      return nil, err
    end
  end

  local parent = vim.fs.dirname(to)
  if vim.fn.mkdir(parent, "p") == 0 and not uv.fs_stat(parent) then
    return nil, ("Cannot create directory `%s`"):format(parent)
  end
  if source.type == "link" then
    local target, read_err = uv.fs_readlink(from)
    if not target then
      return nil, ("Cannot read symbolic link `%s`:\n%s"):format(from, read_err or "unknown error")
    end
    local ok, link_err = uv.fs_symlink(target, to)
    if not ok then
      return nil, ("Cannot copy symbolic link to `%s`:\n%s"):format(to, link_err or "unknown error")
    end
    return true
  end

  local ok, copy_err = uv.fs_copyfile(from, to)
  if not ok then
    return nil, ("Cannot copy file to `%s`:\n%s"):format(to, copy_err or "unknown error")
  end
  return true
end

---Execute a plan created by `plan`.
---@param plan config.explorer.CopyPlan
---@param opts? {overwrite?:boolean}
---@return boolean? ok
---@return string? error
function M.execute(plan, opts)
  opts = opts or {}
  if #plan.conflicts > 0 and not opts.overwrite then
    return nil, "The copy plan contains destination conflicts"
  end
  for _, entry in ipairs(plan.entries) do
    local ok, err = copy_path(entry.from, entry.to, opts.overwrite == true)
    if not ok then
      return nil, err
    end
  end
  return true
end

return M
