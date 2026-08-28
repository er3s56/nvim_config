local PickerFinder = require("config.picker_finder")

local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
for index = 1, 5 do
  assert(vim.fn.writefile({ "x" }, ("%s/f%d.txt"):format(root, index)) == 0)
end

local original_cwd = vim.fn.getcwd(0)
local picker

local function stats()
  local seen, duplicates = {}, 0
  for index = 1, picker.finder:count() do
    local item = picker.finder.items[index]
    local file = item and item.file
    if file then
      if seen[file] then
        duplicates = duplicates + 1
      end
      seen[file] = true
    end
  end
  return picker.finder:count(), duplicates
end

local ok, test_error = pcall(function()
  vim.cmd.cd(vim.fn.fnameescape(root))
  PickerFinder.setup()
  assert(PickerFinder._patched(), "the Picker finder was never patched")

  -- A Picker torn down before its scheduled `set_layout` callback runs has
  -- `preview` already cleared; without the guard that callback errors with a
  -- notification. Model the three teardown shapes the guard must absorb.
  local Picker = require("snacks.picker.core.picker")
  for _, gutted in ipairs({
    { closed = true, preview = {} },
    { closed = false, preview = nil },
    { closed = false, _activity_closing = true, preview = {} },
  }) do
    local layout_ok, layout_error = pcall(Picker.set_layout, gutted, nil)
    assert(
      layout_ok,
      ("set_layout on a torn-down picker errored instead of no-oping: %s"):format(tostring(layout_error))
    )
  end

  picker = Snacks.explorer({ cwd = root, auto_close = false, enter = false, focus = false })
  assert(picker, "the Explorer picker did not open")
  assert(
    vim.wait(5000, function()
      return picker.finder:count() > 0 and not picker.finder:running()
    end, 50),
    "the Explorer picker never produced any items"
  )
  local baseline, duplicates = stats()
  assert(duplicates == 0, "the Explorer picker started out with duplicates")

  -- Two finds in the same tick: the first run's coroutine has not been resumed
  -- yet when the second one aborts it and replaces the item table. Aborting a
  -- coroutine that never started only schedules a resume, so without the patch
  -- the superseded run wakes up and appends its whole output to its
  -- successor's list, leaving every entry in the tree twice.
  for _ = 1, 2 do
    picker:find()
  end
  assert(
    vim.wait(5000, function()
      return not picker.finder:running()
    end, 50),
    "the finder never settled"
  )
  vim.wait(300)

  local count, repeated = stats()
  assert(
    repeated == 0,
    ("a superseded finder run left %d duplicated entries behind (items=%d)"):format(repeated, count)
  )
  assert(count == baseline, ("the item count changed from %d to %d across a re-find"):format(baseline, count))
end)

if picker and not picker.closed then
  pcall(function()
    picker:close()
  end)
end
vim.cmd.cd(vim.fn.fnameescape(original_cwd))
vim.fn.delete(root, "rf")
assert(ok, test_error)

print("picker-finder-ok")
