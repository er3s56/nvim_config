-- Everything the project Git panel does that changes the repository.
--
-- The panel itself only reads -- `status`, `log`, `show` -- and every write
-- lives here: staging, unstaging and discarding, for a whole file or for a
-- single hunk.
--
-- Hunk operations never build a patch for `git apply`. A patch has to match
-- its context exactly, which turns every CRLF, trailing newline and stale
-- offset into a silent failure or, worse, a hunk applied in the wrong place.
-- The panel already holds both sides of the diff, so the entire new side is
-- composed in memory and handed to git as a blob instead. What is written is
-- then a whole file, not an instruction to be re-interpreted.

local uv = vim.uv or vim.loop

local M = {}

-- Statuses git reports for a path in a merge conflict. Both letters carry
-- conflict state there, so the usual "index column / worktree column" reading
-- of the code does not apply.
local UNMERGED = {
  DD = true,
  AU = true,
  UD = true,
  UA = true,
  DU = true,
  AA = true,
  UU = true,
}

local function run(root, args, opts, callback)
  local cmd = { "git", "--no-optional-locks", "-C", root }
  vim.list_extend(cmd, args)
  opts = vim.tbl_extend("keep", opts or {}, { text = true })
  vim.system(cmd, opts, function(result)
    vim.schedule(function()
      callback(result)
    end)
  end)
end

local function failure(args, result)
  local detail = vim.trim(result.stderr or "")
  return ("git %s failed (exit %s)%s"):format(args[1], tostring(result.code), detail ~= "" and ": " .. detail or "")
end

-- Reporting the outcome as `callback(ok and nil or failure())` would always
-- report a failure: the true branch yields nil, which sends the expression
-- straight on to `or`.
local function report(callback, args, result)
  if result.code == 0 then
    return callback(nil)
  end
  callback(failure(args, result))
end

-- Run a list of `function(next)` steps in order, stopping at the first that
-- reports an error. Git operations have to be chained rather than fired in
-- parallel: they all take the index lock.
local function chain(steps, callback)
  local index = 0
  local function step(err)
    if err then
      return callback(err)
    end
    index = index + 1
    local next_step = steps[index]
    if not next_step then
      return callback(nil)
    end
    next_step(step)
  end
  step(nil)
end

function M.is_unmerged(status)
  return UNMERGED[status or ""] == true
end

-- Which operations a row allows. VSCode answers this by which group the row
-- sits in, and so does the panel: a file that is both staged and modified has
-- a row in each of the two groups, and each row acts on the one column of the
-- status its group is about. Passing no group asks the code to answer alone,
-- which is every column at once.
function M.file_actions(status, group)
  status = status or ""
  if M.is_unmerged(status) then
    -- Staging a conflicted path is how git records it as resolved, and
    -- discarding takes both sides back to HEAD.
    return { stage = true, unstage = false, discard = true }
  end
  if status == "??" then
    return { stage = true, unstage = false, discard = true }
  end
  local index, worktree = status:sub(1, 1), status:sub(2, 2)
  local staged = index ~= " " and index ~= ""
  local dirty = worktree ~= " " and worktree ~= ""
  if group == "staged" then
    -- The index side of the file. Discarding is not offered here: what the
    -- staged group can throw away is the staging, which is unstaging.
    return { stage = false, unstage = staged, discard = false }
  end
  if group == "changes" then
    return { stage = dirty, unstage = false, discard = dirty }
  end
  return { stage = dirty, unstage = staged, discard = dirty }
end

-- ── text ────────────────────────────────────────────────────────────────

function M.is_binary(content)
  return (content or ""):find("\0", 1, true) ~= nil
end

-- Split the way the preview buffers do, so a hunk's line numbers mean the same
-- thing in the diff windows and in the content written back. A file's final
-- newline terminates its last line rather than starting an empty one, and is
-- remembered separately so it can be restored exactly.
function M.split_lines(content)
  content = content or ""
  local trailing = content:sub(-1) == "\n"
  if trailing then
    content = content:sub(1, -2)
  end
  if content == "" then
    return {}, trailing
  end
  return vim.split(content, "\n", { plain = true }), trailing
end

function M.join_lines(lines, trailing)
  if #lines == 0 then
    return trailing and "\n" or ""
  end
  return table.concat(lines, "\n") .. (trailing and "\n" or "")
end

---@return { before_start: number, before_count: number, after_start: number, after_count: number }[]
function M.hunks(before, after)
  local result = {}
  for _, hunk in ipairs(vim.diff(before, after, { result_type = "indices" }) or {}) do
    result[#result + 1] = {
      before_start = hunk[1],
      before_count = hunk[2],
      after_start = hunk[3],
      after_count = hunk[4],
    }
  end
  return result
end

-- The hunk covering a line of one side, for a click in that diff window. A
-- pure insertion has no lines on the other side, so it is claimed by the line
-- it sits after -- otherwise clicking the only row a change occupies would
-- find nothing.
function M.hunk_at(hunks, side, line)
  local start_key = side == "before" and "before_start" or "after_start"
  local count_key = side == "before" and "before_count" or "after_count"
  for index, hunk in ipairs(hunks) do
    local start, count = hunk[start_key], hunk[count_key]
    if count == 0 then
      if line == start or line == start + 1 then
        return hunk, index
      end
    elseif line >= start and line <= start + count - 1 then
      return hunk, index
    end
  end
end

-- Replace `count` lines of `target` from `start` with `insert`, honouring the
-- diff convention that a zero count means "after this line" rather than "at
-- this line".
local function splice(target, start, count, insert)
  local result = {}
  local keep_until = count > 0 and start - 1 or start
  local resume_from = count > 0 and start + count or start + 1
  for line = 1, math.min(keep_until, #target) do
    result[#result + 1] = target[line]
  end
  vim.list_extend(result, insert)
  for line = resume_from, #target do
    result[#result + 1] = target[line]
  end
  return result
end

local function slice(lines, start, count)
  local result = {}
  for line = start, start + count - 1 do
    result[#result + 1] = lines[line]
  end
  return result
end

-- Whether a hunk reaches the end of a side. Only then does the result take
-- that side's final newline: a file that ends without one differs from one
-- that does, and git records it as a change like any other.
local function touches_end(start, count, total)
  return (count > 0 and start + count - 1 or start) >= total
end

local function transplant(target_content, source_content, target_start, target_count, source_start, source_count)
  local target, target_trailing = M.split_lines(target_content)
  local source, source_trailing = M.split_lines(source_content)
  local lines = splice(target, target_start, target_count, slice(source, source_start, source_count))
  local trailing = target_trailing
  if touches_end(target_start, target_count, #target) and touches_end(source_start, source_count, #source) then
    trailing = source_trailing
  end
  return M.join_lines(lines, trailing)
end

-- `before` rewritten so that this hunk reads the way `after` does: the content
-- to stage.
function M.apply_hunk(before, after, hunk)
  return transplant(before, after, hunk.before_start, hunk.before_count, hunk.after_start, hunk.after_count)
end

-- `after` rewritten so that this hunk reads the way `before` does again: the
-- content to leave behind when a hunk is discarded or unstaged.
function M.revert_hunk(before, after, hunk)
  return transplant(after, before, hunk.after_start, hunk.after_count, hunk.before_start, hunk.before_count)
end

-- ── repository reads ────────────────────────────────────────────────────

function M.read_worktree(root, path)
  local file = io.open(vim.fs.joinpath(root, path), "rb")
  if not file then
    return nil, ("Cannot read `%s` from the working tree"):format(path)
  end
  local content = file:read("*a")
  file:close()
  return content or ""
end

local function read_blob(root, spec, callback)
  run(root, { "show", spec }, { text = false }, function(result)
    if result.code ~= 0 then
      return callback(nil, vim.trim(result.stderr or ""))
    end
    callback(result.stdout or "")
  end)
end

-- The index side of a path, or an empty string when the path is not in the
-- index at all -- a file staged for the first time has no previous version,
-- which is not an error.
local function read_index(root, path, callback)
  read_blob(root, ":" .. path, function(content, err)
    if content then
      return callback(content)
    end
    run(root, { "ls-files", "--error-unmatch", "--", path }, {}, function(result)
      if result.code == 0 then
        return callback(nil, err)
      end
      callback("")
    end)
  end)
end

local function read_head(root, path, callback)
  read_blob(root, "HEAD:" .. path, function(content)
    callback(content or "")
  end)
end

-- ── repository writes ───────────────────────────────────────────────────

local function write_worktree(root, path, content)
  local full = vim.fs.joinpath(root, path)
  local file, err = io.open(full, "wb")
  if not file then
    return ("Cannot write `%s`: %s"):format(path, tostring(err))
  end
  local ok, write_err = file:write(content)
  file:close()
  if not ok then
    return ("Cannot write `%s`: %s"):format(path, tostring(write_err))
  end
end

-- The mode to record for a path. An entry already in the index keeps the mode
-- it has; a new one takes the executable bit from the file on disk, the way
-- `git add` would.
local function index_mode(root, path, callback)
  run(root, { "ls-files", "--stage", "--", path }, {}, function(result)
    local mode = result.code == 0 and (result.stdout or ""):match("^(%d+)") or nil
    if mode then
      return callback(mode)
    end
    local executable = uv.fs_access(vim.fs.joinpath(root, path), "X")
    callback(executable and "100755" or "100644")
  end)
end

local function stage_content(root, path, content, callback)
  index_mode(root, path, function(mode)
    run(root, { "hash-object", "-w", "--stdin" }, { stdin = content }, function(hashed)
      if hashed.code ~= 0 then
        return callback(failure({ "hash-object" }, hashed))
      end
      local sha = vim.trim(hashed.stdout or "")
      if not sha:match("^%x+$") then
        return callback("git hash-object returned no object name")
      end
      local args = { "update-index", "--add", "--cacheinfo", ("%s,%s,%s"):format(mode, sha, path) }
      run(root, args, {}, function(result)
        report(callback, args, result)
      end)
    end)
  end)
end

function M.stage(root, paths, callback)
  if #paths == 0 then
    return callback(nil)
  end
  local args = { "add", "--all", "--" }
  vim.list_extend(args, paths)
  run(root, args, {}, function(result)
    report(callback, args, result)
  end)
end

function M.unstage(root, paths, callback)
  if #paths == 0 then
    return callback(nil)
  end
  -- `restore --staged` restores the index from HEAD, and before the first
  -- commit there is no HEAD to restore from. Dropping the entry is then the
  -- whole of what unstaging can mean.
  run(root, { "rev-parse", "--verify", "--quiet", "HEAD" }, {}, function(head)
    local args = head.code == 0 and { "restore", "--staged", "--" }
      or { "rm", "--cached", "--force", "--quiet", "--" }
    vim.list_extend(args, paths)
    run(root, args, {}, function(result)
      report(callback, args, result)
    end)
  end)
end

-- Discarding is the one operation that destroys work no other command can
-- bring back, so each kind of change is taken back by exactly the command that
-- undoes it and nothing wider: never a `clean`, never a `checkout .`.
function M.discard(root, changes, callback)
  local untracked, restore, unmerged = {}, {}, {}
  for _, change in ipairs(changes) do
    -- A path whose working tree already matches the index has nothing to
    -- discard; leaving it out keeps a "discard all" from touching it.
    if M.file_actions(change.status).discard then
      if M.is_unmerged(change.status) then
        unmerged[#unmerged + 1] = change.path
      elseif change.status == "??" then
        untracked[#untracked + 1] = change.path
      else
        restore[#restore + 1] = change.path
      end
    end
  end

  local steps = {}
  if #untracked > 0 then
    steps[#steps + 1] = function(next_step)
      for _, path in ipairs(untracked) do
        -- git collapses an untracked directory into a single `dir/` entry.
        local full = vim.fs.joinpath(root, path)
        if vim.fn.delete(full, "rf") ~= 0 and uv.fs_stat(full) then
          return next_step(("Cannot delete `%s`"):format(path))
        end
      end
      next_step(nil)
    end
  end
  if #restore > 0 then
    steps[#steps + 1] = function(next_step)
      local args = { "restore", "--" }
      vim.list_extend(args, restore)
      run(root, args, {}, function(result)
        report(next_step, args, result)
      end)
    end
  end
  if #unmerged > 0 then
    steps[#steps + 1] = function(next_step)
      local args = { "restore", "--source=HEAD", "--staged", "--worktree", "--" }
      vim.list_extend(args, unmerged)
      run(root, args, {}, function(result)
        report(next_step, args, result)
      end)
    end
  end
  chain(steps, callback)
end

-- ── hunks ───────────────────────────────────────────────────────────────

-- Both sides of the diff a hunk was taken from, read fresh. `expected` is what
-- the panel's diff was built from: a hunk is a pair of line ranges and means
-- nothing once the file has moved on, so anything written after a mismatch
-- would land in the wrong place. Refusing and refreshing is the only safe
-- answer.
local function with_sides(root, path, mode, expected, callback)
  local read_before = mode == "staged" and read_head or read_index
  local function verify(before, after)
    if before ~= expected.before or after ~= expected.after then
      return callback(nil, nil, "`" .. path .. "` changed since this diff was opened; the panel has been refreshed")
    end
    if M.is_binary(before) or M.is_binary(after) then
      return callback(nil, nil, "`" .. path .. "` is binary; only whole-file operations are available")
    end
    callback(before, after)
  end

  read_before(root, path, function(before, err)
    if not before then
      return callback(nil, nil, err or ("Cannot read the previous version of `" .. path .. "`"))
    end
    if mode == "staged" then
      return read_index(root, path, function(after, index_err)
        if not after then
          return callback(nil, nil, index_err or ("Cannot read the staged version of `" .. path .. "`"))
        end
        verify(before, after)
      end)
    end
    local after, read_err = M.read_worktree(root, path)
    if not after then
      return callback(nil, nil, read_err)
    end
    verify(before, after)
  end)
end

--- Stage one hunk of a file's unstaged (or untracked) changes.
function M.stage_hunk(root, path, hunk, expected, callback)
  with_sides(root, path, "unstaged", expected, function(before, after, err)
    if err then
      return callback(err)
    end
    stage_content(root, path, M.apply_hunk(before, after, hunk), callback)
  end)
end

--- Take one hunk back out of the index, leaving the rest staged.
function M.unstage_hunk(root, path, hunk, expected, callback)
  with_sides(root, path, "staged", expected, function(before, after, err)
    if err then
      return callback(err)
    end
    stage_content(root, path, M.revert_hunk(before, after, hunk), callback)
  end)
end

--- Throw away one hunk of a file's unstaged changes.
function M.discard_hunk(root, path, hunk, expected, callback)
  with_sides(root, path, "unstaged", expected, function(before, after, err)
    if err then
      return callback(err)
    end
    callback(write_worktree(root, path, M.revert_hunk(before, after, hunk)))
  end)
end

M._chain = chain

return M
