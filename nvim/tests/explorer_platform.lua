local Platform = require("config.explorer_platform")

local function assert_equal(expected, actual, message)
  if not vim.deep_equal(expected, actual) then
    error(("%s\nexpected: %s\nactual:   %s"):format(message, vim.inspect(expected), vim.inspect(actual)))
  end
end

local calls = {}
local function record(cmd, opts)
  calls[#calls + 1] = { cmd = cmd, opts = opts or {} }
  return { code = 0, stdout = "", stderr = "" }
end

local wayland = Platform.new({
  platform = "linux",
  getenv = function(name)
    return name == "WAYLAND_DISPLAY" and "wayland-0" or nil
  end,
  executable = function(command)
    return command == "wl-copy" or command == "wl-paste"
  end,
  run = function(cmd, opts)
    if cmd[1] == "wl-paste" and cmd[2] == "--list-types" then
      return { code = 0, stdout = "text/plain\ntext/uri-list\n", stderr = "" }
    elseif cmd[1] == "wl-paste" then
      return { code = 0, stdout = "file:///tmp/a%20b\r\nfile:///tmp/c\r\n", stderr = "" }
    end
    return record(cmd, opts)
  end,
})
assert(wayland:copy_files({ "/tmp/a b", "/tmp/c" }))
assert_equal("wl-copy", calls[#calls].cmd[1], "Wayland did not use wl-copy")
assert(calls[#calls].opts.input:find("file:///tmp/a%%20b"), "Wayland clipboard did not contain file URIs")
assert_equal({ "/tmp/a b", "/tmp/c" }, assert(wayland:read_files()), "Wayland file clipboard parsing failed")

local xclip = Platform.new({
  platform = "linux",
  getenv = function(name)
    return name == "DISPLAY" and ":0" or nil
  end,
  executable = function(command)
    return command == "xclip"
  end,
  run = function(cmd, opts)
    if cmd[#cmd] == "TARGETS" then
      return { code = 0, stdout = "TARGETS\ntext/uri-list\n", stderr = "" }
    elseif cmd[3] == "clipboard" and cmd[4] == "-out" then
      return { code = 0, stdout = "copy\nfile:///tmp/x\n", stderr = "" }
    end
    return record(cmd, opts)
  end,
})
assert(xclip:copy_files({ "/tmp/x" }))
assert_equal("xclip", calls[#calls].cmd[1], "X11 did not use xclip")
assert_equal({ "/tmp/x" }, assert(xclip:read_files()), "xclip parsing failed")

local xsel = Platform.new({
  platform = "linux",
  getenv = function(name)
    return name == "DISPLAY" and ":0" or nil
  end,
  executable = function(command)
    return command == "xsel"
  end,
  run = function(cmd, opts)
    if cmd[#cmd] == "--output" then
      return { code = 0, stdout = "file:///tmp/xsel\n", stderr = "" }
    end
    return record(cmd, opts)
  end,
})
assert(xsel:copy_files({ "/tmp/xsel" }))
assert_equal({ "/tmp/xsel" }, assert(xsel:read_files()), "xsel parsing failed")

local missing_wayland = Platform.new({
  platform = "linux",
  getenv = function(name)
    return name == "WAYLAND_DISPLAY" and "wayland-0" or nil
  end,
  executable = function()
    return false
  end,
})
local missing_ok, missing_err = missing_wayland:copy_files({ "/tmp/a" })
assert_equal(nil, missing_ok, "missing Wayland backend unexpectedly succeeded")
assert(missing_err:find("wl%-clipboard"), missing_err)

local missing_x11 = Platform.new({
  platform = "linux",
  getenv = function(name)
    return name == "DISPLAY" and ":0" or nil
  end,
  executable = function()
    return false
  end,
})
local x11_ok, x11_err = missing_x11:read_files()
assert_equal(nil, x11_ok, "missing X11 backend unexpectedly succeeded")
assert(x11_err:find("xclip", 1, true) and x11_err:find("xsel", 1, true), x11_err)

local powershell_scripts = {}
local wsl = Platform.new({
  platform = "wsl",
  executable = function(command)
    return command == "powershell.exe" or command == "explorer.exe"
  end,
  to_windows = function(path)
    return "C:\\WSL" .. path:gsub("/", "\\")
  end,
  to_unix = function(path)
    return path:gsub("^C:\\WSL", ""):gsub("\\", "/")
  end,
  run = function(cmd)
    if cmd[1] == "powershell.exe" then
      local encoded = cmd[#cmd]
      local decoded = vim.base64.decode(encoded)
      local script = vim.iconv(decoded, "utf-16le", "utf-8")
      powershell_scripts[#powershell_scripts + 1] = script
      if script:find("GetFileDropList", 1, true) then
        return { code = 0, stdout = '["C:\\\\WSL\\\\tmp\\\\roundtrip"]', stderr = "" }
      end
      return { code = 0, stdout = "", stderr = "" }
    end
    local result = record(cmd)
    if cmd[1] == "explorer.exe" then
      result.code = 1
    end
    return result
  end,
})
assert(wsl:copy_files({ "/tmp/roundtrip" }))
assert(
  powershell_scripts[#powershell_scripts]:find("SetFileDropList", 1, true),
  "WSL did not set a Windows file-drop clipboard"
)
assert(
  not powershell_scripts[#powershell_scripts]:find("$paths = @(", 1, true),
  "Windows PowerShell 5 would wrap the decoded path array and merge multiple files"
)
assert_equal({ "/tmp/roundtrip" }, assert(wsl:read_files()), "WSL path round-trip failed")
assert(wsl:open("/tmp/roundtrip"))
assert(powershell_scripts[#powershell_scripts]:find("Invoke%-Item"), "WSL open did not use PowerShell")
assert(wsl:reveal("/tmp/roundtrip"))
assert_equal("explorer.exe", calls[#calls].cmd[1], "WSL reveal did not use Explorer")
assert(wsl:trash("/tmp/roundtrip"))
assert(
  powershell_scripts[#powershell_scripts]:find("SendToRecycleBin", 1, true),
  "WSL trash did not request the Recycle Bin"
)

local mac = Platform.new({
  platform = "mac",
  executable = function(command)
    return command == "osascript" or command == "open"
  end,
  run = function(cmd, opts)
    if cmd[1] == "osascript" and #cmd == 3 then
      return { code = 0, stdout = "/tmp/mac-file\n", stderr = "" }
    end
    return record(cmd, opts)
  end,
})
assert(mac:copy_files({ "/tmp/mac-file" }))
assert_equal({ "/tmp/mac-file" }, assert(mac:read_files()), "macOS clipboard parsing failed")
assert(mac:open("/tmp/mac-file"))
assert(mac:reveal("/tmp/mac-file"))

print("explorer-platform-ok")
