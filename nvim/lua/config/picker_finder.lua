-- Drop results from a Snacks Picker finder run that has been superseded.
--
-- `Finder:run()` starts a new search by aborting the previous one and then
-- replacing the item table:
--
--     self.task:abort()
--     self.items = {}
--
-- `Async:abort()` on a coroutine that has never been resumed does not prevent
-- it from running: it sets the aborted flag and then *schedules* a resume, and
-- the "abort" signal is delivered as the return value of a `yield` the
-- coroutine has not reached yet. Measured in isolation, such a coroutine emits
-- nothing at abort time and its full output one event-loop pass later.
--
-- The superseded finder therefore starts from the beginning on the next tick
-- and runs to completion, and because `add()` inside `run` reads `self.items`
-- when it is called rather than capturing the table it was created for,
-- everything it emits lands in the *new* run's table. The picker is left
-- holding both runs' output: every entry twice, in run order.
--
-- The Explorer hits this because it re-runs its finder several times while a
-- window is being set up (Git status, diagnostics, layout), and one of those
-- runs can start before the previous coroutine has had its first resume. Two
-- finds in the same tick reproduce it every time.
--
-- Tag each run and ignore emissions from a run that is no longer the current
-- one, so a superseded finder can no longer write into its successor's list.
local M = {}

local patched = false

function M.setup()
  if patched then
    return
  end
  local ok, Finder = pcall(require, "snacks.picker.core.finder")
  if not ok or type(Finder) ~= "table" or type(Finder.run) ~= "function" then
    return
  end
  patched = true

  -- A Picker schedules `set_layout` from its VimResized handler. When the
  -- picker is torn down before that callback runs -- routine when sidebar
  -- views are switched quickly -- `init_layout` dereferences `self.preview`,
  -- which teardown has already cleared, and an error notification pops up.
  -- Drop layout updates for a picker that is closing or already gutted.
  local picker_ok, Picker = pcall(require, "snacks.picker.core.picker")
  if picker_ok and type(Picker) == "table" and type(Picker.set_layout) == "function" then
    local original_set_layout = Picker.set_layout
    Picker.set_layout = function(self, ...)
      if self.closed or self._activity_closing or not self.preview then
        return
      end
      return original_set_layout(self, ...)
    end
  end

  local original_run = Finder.run
  Finder.run = function(self, picker)
    self._project_run = (self._project_run or 0) + 1
    local generation = self._project_run
    -- `run` resolves `self._find` once, synchronously, before it starts the
    -- task, so wrapping it just for that call is enough to reach the callback
    -- the task will stream through.
    local original_find = self._find
    self._find = function(...)
      local finder = original_find(...)
      if type(finder) ~= "function" then
        return finder
      end
      return function(cb)
        return finder(function(item)
          if self._project_run ~= generation then
            return
          end
          return cb(item)
        end)
      end
    end
    local completed, result = pcall(original_run, self, picker)
    self._find = original_find
    if not completed then
      error(result, 0)
    end
    return result
  end
end

M._patched = function()
  return patched
end

return M
