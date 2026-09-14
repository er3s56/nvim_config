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
  local cmd = { "git", "--no-optional-locks", "--literal-pathspecs", "-C", root }
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
  if content == "" and not trailing then
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
  local full = vim.fs.joinpath(root, path)
  local stat, stat_err = uv.fs_lstat(full)
  if not stat then
    if stat_err and stat_err:match("^ENOENT:") then
      return ""
    end
    return nil, stat_err or ("Cannot stat `%s`"):format(path)
  end
  if stat.type ~= "file" then
    return nil, ("`%s` is a %s; only whole-file operations are available"):format(path, stat.type)
  end
  local file = io.open(full, "rb")
  if not file then
    return nil, ("Cannot read `%s` from the working tree"):format(path)
  end
  local content, err = file:read("*a")
  file:close()
  return content, err
end

local function read_blob(root, spec, callback, filtered_path)
  local args = filtered_path and { "cat-file", "--filters", "--path=" .. filtered_path, spec } or { "show", spec }
  run(root, args, { text = false }, function(result)
    if result.code ~= 0 then
      return callback(nil, vim.trim(result.stderr or ""))
    end
    callback(result.stdout or "")
  end)
end

-- The index side of a path, or an empty string when the path is not in the
-- index at all -- a file staged for the first time has no previous version,
-- which is not an error.
local function read_index(root, path, callback, filtered)
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
  end, filtered and path or nil)
end

-- A symlink blob contains a path, not the bytes of the file it points at.
-- Check both Git modes and lstat: a regular working file may still be replacing
-- a symlink in the index/HEAD, and an unresolved merge has no stage-zero blob.
function M.check_hunk_file(root, path, opts, callback)
  opts = opts or {}
  local stat, stat_err = uv.fs_lstat(vim.fs.joinpath(root, path))
  if not stat and stat_err and not stat_err:match("^ENOENT:") then
    return callback(nil, stat_err)
  end
  if stat and stat.type ~= "file" then
    return callback(nil, ("`%s` is a %s; only whole-file operations are available"):format(path, stat.type))
  end
  local info = { disk = stat, before_path = opts.before_path or path }
  local function regular(mode)
    return mode == nil or mode == "100644" or mode == "100755"
  end
  run(root, { "ls-files", "--stage", "-z", "--", path }, { text = false }, function(result)
    if result.code ~= 0 then
      return callback(nil, failure({ "ls-files" }, result))
    end
    for _, record in ipairs(vim.split(result.stdout or "", "\0", { plain = true, trimempty = true })) do
      local mode, stage = record:match("^(%d+) %x+ (%d+)\t")
      if stage ~= "0" or not regular(mode) then
        return callback(
          nil,
          "`" .. path .. "` is not a regular stage-zero file; only whole-file operations are available"
        )
      end
      info.index_mode = mode
    end
    if not opts.staged then
      return callback(info)
    end
    run(root, { "rev-parse", "--verify", "--quiet", "HEAD" }, {}, function(head)
      if head.code ~= 0 then
        -- An unborn repository has no HEAD; other failures must be reported.
        if head.code == 1 then
          return callback(info)
        end
        return callback(nil, failure({ "rev-parse" }, head))
      end
      info.head = vim.trim(head.stdout or "")
      run(root, { "ls-tree", "-z", info.head, "--", info.before_path }, { text = false }, function(tree)
        if tree.code ~= 0 then
          return callback(nil, failure({ "ls-tree" }, tree))
        end
        info.head_mode = (tree.stdout or ""):match("^(%d+)")
        if not regular(info.head_mode) then
          return callback(
            nil,
            "`" .. path .. "` was not a regular file in HEAD; only whole-file operations are available"
          )
        end
        callback(info)
      end)
    end)
  end)
end

-- ── repository writes ───────────────────────────────────────────────────

local function write_worktree(root, path, content, expected_stat, mode)
  local full = vim.fs.joinpath(root, path)
  if not expected_stat then
    vim.fn.mkdir(vim.fs.dirname(full), "p")
  end
  -- Do not truncate on open. A link swapped into the path while git was
  -- running must be rejected before a byte of its target can be changed.
  local fd, err = uv.fs_open(full, expected_stat and "r+" or "wx", mode == "100755" and 493 or 438)
  if not fd then
    return ("Cannot write `%s`: %s"):format(path, tostring(err))
  end
  local opened, current = uv.fs_fstat(fd), uv.fs_lstat(full)
  if
    not opened
    or not current
    or current.type ~= "file"
    or opened.ino ~= current.ino
    or opened.dev ~= current.dev
    or expected_stat and (opened.ino ~= expected_stat.ino or opened.dev ~= expected_stat.dev)
  then
    uv.fs_close(fd)
    return "`" .. path .. "` changed type or was replaced; refresh the diff before retrying"
  end
  local offset = 0
  while offset < #content do
    local written, write_err = uv.fs_write(fd, content:sub(offset + 1), offset)
    if not written or written == 0 then
      uv.fs_close(fd)
      return ("Cannot write `%s`: %s"):format(path, tostring(write_err))
    end
    offset = offset + written
  end
  local ok, truncate_err = uv.fs_ftruncate(fd, #content)
  local closed, close_err = uv.fs_close(fd)
  if not ok or not closed then
    return ("Cannot finish writing `%s`: %s"):format(path, tostring(truncate_err or close_err))
  end
end

local function stage_content(root, path, content, info, clean, callback)
  -- Removing the only hunk of a new file unstages the path itself. Likewise,
  -- staging a deleted file must remove its entry, not stage an empty file.
  if content == "" and (clean and not info.disk or not clean and not info.head_mode) then
    local args = { "update-index", "--force-remove", "--", path }
    return run(root, args, {}, function(result)
      report(callback, args, result)
    end)
  end
  local mode = info.index_mode
    or info.head_mode
    or (uv.fs_access(vim.fs.joinpath(root, path), "X") and "100755" or "100644")
  -- Stage from worktree form through this path's clean/eol rules. Unstaging
  -- starts with canonical index blobs, so applying clean a second time is wrong.
  local args = { "hash-object", "-w", "--stdin", clean and ("--path=" .. path) or "--no-filters" }
  run(root, args, { stdin = content, text = false }, function(hashed)
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
  M.check_hunk_file(
    root,
    path,
    { staged = mode == "staged", before_path = expected.before_path },
    function(info, type_err)
      if type_err then
        return callback(nil, nil, type_err)
      end
      local function read_before(done)
        if mode == "staged" then
          if not info.head_mode then
            return done("")
          end
          return read_blob(root, info.head .. ":" .. info.before_path, done)
        end
        return read_index(root, path, done, true)
      end
      local function verify(before, after)
        if before ~= expected.before or after ~= expected.after then
          return callback(nil, nil, "`" .. path .. "` changed since this diff was opened; the panel has been refreshed")
        end
        if M.is_binary(before) or M.is_binary(after) then
          return callback(nil, nil, "`" .. path .. "` is binary; only whole-file operations are available")
        end
        callback(before, after, nil, info)
      end

      read_before(function(before, err)
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
  )
end

--- Stage one hunk of a file's unstaged (or untracked) changes.
function M.stage_hunk(root, path, hunk, expected, callback)
  with_sides(root, path, "unstaged", expected, function(before, after, err, info)
    if err then
      return callback(err)
    end
    stage_content(root, path, M.apply_hunk(before, after, hunk), info, true, callback)
  end)
end

--- Take one hunk back out of the index, leaving the rest staged.
function M.unstage_hunk(root, path, hunk, expected, callback)
  with_sides(root, path, "staged", expected, function(before, after, err, info)
    if err then
      return callback(err)
    end
    stage_content(root, path, M.revert_hunk(before, after, hunk), info, false, callback)
  end)
end

--- Throw away one hunk of a file's unstaged changes.
function M.discard_hunk(root, path, hunk, expected, callback)
  with_sides(root, path, "unstaged", expected, function(before, after, err, info)
    if err then
      return callback(err)
    end
    callback(write_worktree(root, path, M.revert_hunk(before, after, hunk), info.disk, info.index_mode))
  end)
end

M._chain = chain

return M
