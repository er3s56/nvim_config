local uv = vim.uv or vim.loop

local Platform = {}
Platform.__index = Platform

local function trim(value)
  return (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function ps_literal(value)
  return "'" .. value:gsub("'", "''") .. "'"
end

local function encode_powershell(script)
  if not (vim.iconv and vim.base64 and vim.base64.encode) then
    return nil
  end
  local encoded = vim.iconv(script, "utf-8", "utf-16le")
  return encoded and vim.base64.encode(encoded) or nil
end

local function default_run(cmd, opts)
  opts = opts or {}
  local result = vim
    .system(cmd, {
      cwd = opts.cwd,
      env = opts.env,
      stdin = opts.input,
      text = true,
    })
    :wait()
  return {
    code = result.code or 1,
    stdout = result.stdout or "",
    stderr = result.stderr or "",
  }
end

local function default_executable(command)
  return vim.fn.executable(command) == 1
end

local function default_getenv(name)
  return vim.env[name]
end

local function detect_platform(opts)
  if opts.platform then
    return opts.platform
  end
  if vim.fn.has("win32") == 1 then
    return "windows"
  end
  if vim.fn.has("mac") == 1 or vim.fn.has("macunix") == 1 then
    return "mac"
  end
  local uname = uv.os_uname()
  if (uname.release or ""):lower():find("microsoft", 1, true) then
    return "wsl"
  end
  return "linux"
end

---@param opts? table
function Platform.new(opts)
  opts = opts or {}
  local self = setmetatable({}, Platform)
  self.platform = detect_platform(opts)
  self.run = opts.run or default_run
  self.executable = opts.executable or default_executable
  self.getenv = opts.getenv or default_getenv
  self.to_windows_override = opts.to_windows
  self.to_unix_override = opts.to_unix
  return self
end

function Platform:_find_executable(commands)
  for _, command in ipairs(commands) do
    if self.executable(command) then
      return command
    end
  end
end

function Platform:_powershell()
  return self:_find_executable({ "powershell.exe", "powershell", "pwsh.exe", "pwsh" })
end

function Platform:_run_powershell(script)
  local powershell = self:_powershell()
  if not powershell then
    return { code = 127, stdout = "", stderr = "PowerShell is not available" }
  end
  local encoded = encode_powershell(script)
  if encoded then
    return self.run({ powershell, "-NoLogo", "-NoProfile", "-NonInteractive", "-STA", "-EncodedCommand", encoded })
  end
  return self.run({ powershell, "-NoLogo", "-NoProfile", "-NonInteractive", "-STA", "-Command", script })
end

function Platform:_to_windows(path)
  if self.to_windows_override then
    return self.to_windows_override(path)
  end
  if self.platform == "windows" then
    return path
  end
  local result = self.run({ "wslpath", "-w", path })
  if result.code ~= 0 then
    return nil, trim(result.stderr) ~= "" and trim(result.stderr) or "wslpath could not convert the path"
  end
  return trim(result.stdout)
end

function Platform:_to_unix(path)
  if self.to_unix_override then
    return self.to_unix_override(path)
  end
  if self.platform == "windows" then
    return path
  end
  local result = self.run({ "wslpath", "-u", path })
  if result.code ~= 0 then
    return nil, trim(result.stderr) ~= "" and trim(result.stderr) or "wslpath could not convert the path"
  end
  return trim(result.stdout)
end

function Platform:_clipboard_kind()
  if self.platform == "wsl" or self.platform == "windows" then
    if not self:_powershell() then
      return nil, "PowerShell is required for the Windows file clipboard."
    end
    return "windows"
  end
  if self.platform == "mac" then
    if not self.executable("osascript") then
      return nil, "macOS file clipboard support requires `osascript`."
    end
    return "mac"
  end
  if trim(self.getenv("WAYLAND_DISPLAY")) ~= "" then
    if not self.executable("wl-copy") or not self.executable("wl-paste") then
      return nil,
        "Wayland file clipboard support requires `wl-copy` and `wl-paste`. Install the `wl-clipboard` package."
    end
    return "wayland"
  end
  if trim(self.getenv("DISPLAY")) ~= "" then
    if self.executable("xclip") then
      return "xclip"
    end
    if self.executable("xsel") then
      return "xsel"
    end
    return nil, "X11 file clipboard support requires `xclip` or `xsel`."
  end
  return nil, "No Wayland or X11 desktop session was detected; a system file clipboard is unavailable."
end

local function uri_payload(paths, gnome)
  local uris = {}
  for _, path in ipairs(paths) do
    uris[#uris + 1] = vim.uri_from_fname(path)
  end
  if gnome then
    table.insert(uris, 1, "copy")
  end
  return table.concat(uris, "\r\n") .. "\r\n"
end

local function parse_uri_payload(payload)
  local paths = {}
  for line in payload:gsub("\r", ""):gmatch("[^\n]+") do
    if line ~= "copy" and line ~= "cut" and line:sub(1, 1) ~= "#" then
      local path = line
      if line:match("^file:") then
        local ok, decoded = pcall(vim.uri_to_fname, line)
        path = ok and decoded or nil
      end
      if path and path ~= "" then
        paths[#paths + 1] = path
      end
    end
  end
  return paths
end

---@param paths string[]
---@return boolean? ok
---@return string? error
function Platform:copy_files(paths)
  local kind, kind_err = self:_clipboard_kind()
  if not kind then
    return nil, kind_err
  end
  if #paths == 0 then
    return nil, "No files were selected"
  end

  local result
  if kind == "windows" then
    local converted = {}
    for _, path in ipairs(paths) do
      local windows_path, err = self:_to_windows(path)
      if not windows_path then
        return nil, err
      end
      converted[#converted + 1] = windows_path
    end
    local json = vim.json.encode(converted)
    local script = table.concat({
      "Add-Type -AssemblyName System.Windows.Forms",
      "$paths = ConvertFrom-Json -InputObject " .. ps_literal(json),
      "$files = New-Object System.Collections.Specialized.StringCollection",
      "foreach ($path in $paths) { [void]$files.Add([string]$path) }",
      "[System.Windows.Forms.Clipboard]::SetFileDropList($files)",
    }, "; ")
    result = self:_run_powershell(script)
  elseif kind == "mac" then
    local script = [[
on run argv
  set fileList to {}
  repeat with itemPath in argv
    set end of fileList to (POSIX file itemPath as alias)
  end repeat
  set the clipboard to fileList
end run
]]
    local cmd = { "osascript", "-e", script }
    vim.list_extend(cmd, paths)
    result = self.run(cmd)
  elseif kind == "wayland" then
    result = self.run({ "wl-copy", "--type", "text/uri-list" }, { input = uri_payload(paths, false) })
  elseif kind == "xclip" then
    result = self.run({ "xclip", "-selection", "clipboard", "-in", "-target", "text/uri-list" }, {
      input = uri_payload(paths, false),
    })
  else
    result = self.run({ "xsel", "--clipboard", "--input" }, { input = uri_payload(paths, false) })
  end

  if result.code ~= 0 then
    local err = trim(result.stderr)
    return nil, err ~= "" and err or ("The %s file clipboard command failed"):format(kind)
  end
  return true
end

---@return string[]? paths
---@return string? error
function Platform:read_files()
  local kind, kind_err = self:_clipboard_kind()
  if not kind then
    return nil, kind_err
  end

  if kind == "windows" then
    local script = table.concat({
      "Add-Type -AssemblyName System.Windows.Forms",
      "$files = @([System.Windows.Forms.Clipboard]::GetFileDropList() | ForEach-Object { [string]$_ })",
      "[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)",
      "$OutputEncoding = [Console]::OutputEncoding",
      "ConvertTo-Json -Compress -InputObject $files",
    }, "; ")
    local result = self:_run_powershell(script)
    if result.code ~= 0 then
      return nil, trim(result.stderr) ~= "" and trim(result.stderr) or "Could not read the Windows file clipboard"
    end
    local output = trim(result.stdout):gsub("^\239\187\191", "")
    if output == "" then
      return {}, nil
    end
    local ok, decoded = pcall(vim.json.decode, output)
    if not ok then
      return nil, "The Windows file clipboard returned invalid data"
    end
    if type(decoded) == "string" then
      decoded = { decoded }
    end
    local paths = {}
    for _, path in ipairs(decoded or {}) do
      local unix_path, err = self:_to_unix(path)
      if not unix_path then
        return nil, err
      end
      paths[#paths + 1] = unix_path
    end
    return paths
  end

  if kind == "mac" then
    local script = [[
on run
  try
    set fileList to the clipboard as alias list
  on error
    try
      set fileList to {the clipboard as alias}
    on error
      return ""
    end try
  end try
  set output to ""
  repeat with fileItem in fileList
    set output to output & POSIX path of fileItem & linefeed
  end repeat
  return output
end run
]]
    local result = self.run({ "osascript", "-e", script })
    if result.code ~= 0 then
      return nil, trim(result.stderr) ~= "" and trim(result.stderr) or "Could not read the macOS file clipboard"
    end
    return parse_uri_payload(result.stdout)
  end

  local result
  if kind == "wayland" then
    local types = self.run({ "wl-paste", "--list-types" })
    if types.code ~= 0 then
      return nil, trim(types.stderr) ~= "" and trim(types.stderr) or "The Wayland clipboard is empty"
    end
    local mime = types.stdout:find("x%-special/gnome%-copied%-files") and "x-special/gnome-copied-files"
      or types.stdout:find("text/uri%-list") and "text/uri-list"
    if not mime then
      return {}, nil
    end
    result = self.run({ "wl-paste", "--no-newline", "--type", mime })
  elseif kind == "xclip" then
    local types = self.run({ "xclip", "-selection", "clipboard", "-out", "-target", "TARGETS" })
    local mime = types.stdout:find("x%-special/gnome%-copied%-files") and "x-special/gnome-copied-files"
      or types.stdout:find("text/uri%-list") and "text/uri-list"
    if types.code ~= 0 or not mime then
      return {}, nil
    end
    result = self.run({ "xclip", "-selection", "clipboard", "-out", "-target", mime })
  else
    result = self.run({ "xsel", "--clipboard", "--output" })
  end
  if result.code ~= 0 then
    return nil, trim(result.stderr) ~= "" and trim(result.stderr) or ("Could not read the %s clipboard"):format(kind)
  end
  return parse_uri_payload(result.stdout)
end

local function command_error(result, fallback)
  if result.code == 0 then
    return true
  end
  local detail = trim(result.stderr)
  return nil, detail ~= "" and detail or fallback
end

---@param path string
function Platform:open(path)
  if self.platform == "wsl" or self.platform == "windows" then
    local windows_path, err = self:_to_windows(path)
    if not windows_path then
      return nil, err
    end
    return command_error(
      self:_run_powershell("Invoke-Item -LiteralPath " .. ps_literal(windows_path)),
      "Windows could not open the item"
    )
  elseif self.platform == "mac" then
    if not self.executable("open") then
      return nil, "The macOS `open` command is unavailable"
    end
    return command_error(self.run({ "open", path }), "macOS could not open the item")
  end
  if not self.executable("xdg-open") then
    return nil, "Linux desktop integration requires `xdg-open`."
  end
  return command_error(self.run({ "xdg-open", path }), "The desktop could not open the item")
end

---@param path string
function Platform:reveal(path)
  if self.platform == "wsl" or self.platform == "windows" then
    local explorer = self:_find_executable({ "explorer.exe", "explorer" })
    if not explorer then
      return nil, "Windows Explorer is unavailable"
    end
    local windows_path, err = self:_to_windows(path)
    if not windows_path then
      return nil, err
    end
    local result = self.run({ explorer, "/select," .. windows_path })
    -- explorer.exe commonly returns 1 after handing /select off to an
    -- existing Explorer process, including for a successful WSL UNC path.
    if result.code == 0 or (result.code == 1 and trim(result.stderr) == "") then
      return true
    end
    return command_error(result, "Windows Explorer could not reveal the item")
  elseif self.platform == "mac" then
    if not self.executable("open") then
      return nil, "The macOS `open` command is unavailable"
    end
    return command_error(self.run({ "open", "-R", path }), "Finder could not reveal the item")
  end

  local uri = vim.uri_from_fname(path)
  if self.executable("dbus-send") then
    local result = self.run({
      "dbus-send",
      "--session",
      "--dest=org.freedesktop.FileManager1",
      "--type=method_call",
      "/org/freedesktop/FileManager1",
      "org.freedesktop.FileManager1.ShowItems",
      "array:string:" .. uri,
      "string:",
    })
    if result.code == 0 then
      return true
    end
  end
  if self.executable("xdg-open") then
    local result = self.run({ "xdg-open", vim.fs.dirname(path) })
    if result.code == 0 then
      return true, "The file manager does not expose item selection; opened the parent directory instead."
    end
  end
  return nil, "No Linux file manager integration is available (`dbus-send` or `xdg-open`)."
end

function Platform:trash_available()
  if self.platform == "wsl" or self.platform == "windows" then
    return self:_powershell() ~= nil or self.executable("gio") or self.executable("trash-put")
  elseif self.platform == "mac" then
    return self.executable("osascript")
  end
  return self.executable("gio") or self.executable("trash-put")
end

---@param path string
function Platform:trash(path)
  local errors = {}
  if self.platform == "wsl" or self.platform == "windows" then
    if self:_powershell() then
      local windows_path, convert_err = self:_to_windows(path)
      if windows_path then
        local script = table.concat({
          "Add-Type -AssemblyName Microsoft.VisualBasic",
          "$path = " .. ps_literal(windows_path),
          "$ui = [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs",
          "$recycle = [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin",
          "if ([System.IO.Directory]::Exists($path)) { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($path, $ui, $recycle) } else { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($path, $ui, $recycle) }",
        }, "; ")
        local result = self:_run_powershell(script)
        if result.code == 0 then
          return true
        end
        errors[#errors + 1] = trim(result.stderr) ~= "" and trim(result.stderr)
          or "Windows Recycle Bin rejected the item"
      else
        errors[#errors + 1] = convert_err
      end
    end
  elseif self.platform == "mac" then
    if not self.executable("osascript") then
      return nil, "macOS Trash integration requires `osascript`"
    end
    local script = [[on run argv
tell application "Finder" to delete (POSIX file (item 1 of argv) as alias)
end run]]
    return command_error(self.run({ "osascript", "-e", script, path }), "Finder could not move the item to Trash")
  end

  if self.executable("gio") then
    local result = self.run({ "gio", "trash", path })
    if result.code == 0 then
      return true
    end
    errors[#errors + 1] = trim(result.stderr) ~= "" and trim(result.stderr) or "`gio trash` failed"
  end
  if self.executable("trash-put") then
    local result = self.run({ "trash-put", path })
    if result.code == 0 then
      return true
    end
    errors[#errors + 1] = trim(result.stderr) ~= "" and trim(result.stderr) or "`trash-put` failed"
  end
  if #errors == 0 then
    errors[1] = "No system trash command is installed (use `gio` or `trash-cli`)"
  end
  return nil, table.concat(errors, "\n")
end

local default = Platform.new()
local M = { Platform = Platform }

for _, method in ipairs({ "copy_files", "read_files", "open", "reveal", "trash", "trash_available" }) do
  M[method] = function(...)
    return default[method](default, ...)
  end
end

function M.kind()
  return default.platform
end

function M.new(opts)
  return Platform.new(opts)
end

return M
