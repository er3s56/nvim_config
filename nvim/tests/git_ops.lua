local GitOps = require("config.git_ops")

local unpack_list = table.unpack or unpack

local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")

local function git(args)
  local command = { "git", "-C", root }
  vim.list_extend(command, args)
  local result = vim.system(command, { text = true }):wait()
  assert(result.code == 0, table.concat(args, " ") .. ": " .. (result.stderr or ""))
  return result.stdout or ""
end

local function write(path, content)
  local full = vim.fs.joinpath(root, path)
  vim.fn.mkdir(vim.fs.dirname(full), "p")
  local file = assert(io.open(full, "wb"))
  file:write(content)
  file:close()
end

local function read(path)
  local file = io.open(vim.fs.joinpath(root, path), "rb")
  if not file then
    return nil
  end
  local content = file:read("*a")
  file:close()
  return content
end

-- The operations are asynchronous because they shell out to git. Every test
-- wants the result before it can assert on it.
local function sync(fn, ...)
  local args = { ... }
  local done, captured = false, nil
  args[#args + 1] = function(...)
    captured = { ... }
    done = true
  end
  fn(unpack_list(args, 1, #args))
  assert(vim.wait(10000, function()
    return done
  end), "a git operation never finished")
  return unpack_list(captured, 1, #captured)
end

-- Every operation reports a failure as a message, so a test that ignores it
-- would assert on the state git never reached and say nothing about why.
local function must(err, what)
  assert(err == nil, what .. ": " .. tostring(err))
end

local function status_of(path)
  for _, line in ipairs(vim.split(git({ "status", "--porcelain" }), "\n", { trimempty = true })) do
    if line:sub(4) == path then
      return line:sub(1, 2)
    end
  end
end

local ok, test_error = pcall(function()
  -- ── text helpers ──────────────────────────────────────────────────────
  local lines, trailing = GitOps.split_lines("a\nb\n")
  assert(#lines == 2 and lines[2] == "b" and trailing, "a final newline must terminate the last line, not add one")
  assert(GitOps.join_lines(lines, trailing) == "a\nb\n", "join_lines did not restore the content")
  lines, trailing = GitOps.split_lines("a\nb")
  assert(#lines == 2 and not trailing, "a file without a final newline must be reported as such")
  assert(GitOps.join_lines(lines, trailing) == "a\nb", "join_lines invented a final newline")
  lines, trailing = GitOps.split_lines("")
  assert(#lines == 0 and not trailing, "an empty file has no lines")
  assert(GitOps.split_lines("a\r\nb\n")[1] == "a\r", "carriage returns must survive: they are part of the file")

  -- ── hunk arithmetic ───────────────────────────────────────────────────
  local before = "one\ntwo\nthree\nfour\n"
  local after = "one\nTWO\nthree\nfour\nfive\n"
  local hunks = GitOps.hunks(before, after)
  assert(#hunks == 2, ("expected a change and an append, got %d hunks"):format(#hunks))
  assert(GitOps.apply_hunk(before, after, hunks[1]) == "one\nTWO\nthree\nfour\n", "staging one hunk took the other too")
  assert(GitOps.apply_hunk(before, after, hunks[2]) == "one\ntwo\nthree\nfour\nfive\n", "the appended line was lost")
  local reverted = GitOps.revert_hunk(before, after, hunks[1])
  assert(reverted == "one\ntwo\nthree\nfour\nfive\n", "reverting took the wrong hunk")
  assert(GitOps.revert_hunk(before, after, hunks[2]) == "one\nTWO\nthree\nfour\n", "the appended line was not reverted")

  -- A pure deletion has no lines on the other side, so the row a click lands
  -- on is the one it sits after.
  local deletion = GitOps.hunks("one\ntwo\nthree\n", "one\nthree\n")
  assert(#deletion == 1 and deletion[1].after_count == 0, "expected a single deletion hunk")
  assert(GitOps.hunk_at(deletion, "after", 1) == deletion[1], "a deletion is unreachable from the side that lost it")
  assert(GitOps.hunk_at(deletion, "before", 2) == deletion[1], "a deletion is unreachable from its own lines")
  assert(GitOps.hunk_at(deletion, "before", 3) == nil, "an unchanged line claimed a hunk")

  -- A file that ends without a newline differs from one that ends with it,
  -- and git records that difference like any other.
  local ends_bare = GitOps.hunks("a\nb\n", "a\nB")
  assert(GitOps.apply_hunk("a\nb\n", "a\nB", ends_bare[1]) == "a\nB", "the missing final newline was invented")

  -- ── which actions a status allows ─────────────────────────────────────
  local function actions(status)
    local allowed = GitOps.file_actions(status)
    local function mark(allow, letter)
      return allow and letter or "-"
    end
    return mark(allowed.stage, "s") .. mark(allowed.unstage, "u") .. mark(allowed.discard, "d")
  end
  assert(actions(" M") == "s-d", "an unstaged change must offer stage and discard")
  assert(actions("M ") == "-u-", "a staged change must offer unstage only")
  assert(actions("MM") == "sud", "a partly staged change must offer all three")
  assert(actions("??") == "s-d", "an untracked file must offer stage and discard")
  assert(actions("A ") == "-u-", "a newly staged file must offer unstage only")
  assert(actions("UU") == "s-d", "a conflict must offer stage (resolve) and discard")

  -- ── against a real repository ─────────────────────────────────────────
  git({ "init", "-q" })
  git({ "config", "user.name", "Git Ops Test" })
  git({ "config", "user.email", "git-ops@example.invalid" })
  write("file.txt", "one\ntwo\nthree\nfour\nfive\n")
  git({ "add", "file.txt" })
  git({ "commit", "-qm", "initial" })

  write("file.txt", "ONE\ntwo\nthree\nfour\nFIVE\n")
  assert(status_of("file.txt") == " M", "the fixture did not start from an unstaged change")
  must(sync(GitOps.stage, root, { "file.txt" }), "staging a file failed")
  assert(status_of("file.txt") == "M ", "the file was not staged")
  must(sync(GitOps.unstage, root, { "file.txt" }), "unstaging a file failed")
  assert(status_of("file.txt") == " M", "the file was not unstaged")
  must(sync(GitOps.discard, root, { { path = "file.txt", status = " M" } }), "discarding a file failed")
  assert(status_of("file.txt") == nil, "the discarded change is still reported")
  assert(read("file.txt") == "one\ntwo\nthree\nfour\nfive\n", "discard did not restore the file's contents")

  -- An untracked file has no previous version to restore, so discarding it is
  -- a deletion -- and unstaging it has to work without a HEAD version too.
  write("new.txt", "fresh\n")
  assert(status_of("new.txt") == "??", "the new file is not untracked")
  must(sync(GitOps.stage, root, { "new.txt" }), "staging a new file failed")
  assert(status_of("new.txt") == "A ", "the new file was not staged")
  must(sync(GitOps.unstage, root, { "new.txt" }), "unstaging a new file failed")
  assert(status_of("new.txt") == "??", "the new file was not unstaged")
  must(sync(GitOps.discard, root, { { path = "new.txt", status = "??" } }), "discarding a new file failed")
  assert(read("new.txt") == nil, "discarding an untracked file did not delete it")

  -- ── one hunk at a time ────────────────────────────────────────────────
  local base = assert(read("file.txt"))
  local edited = "ONE\ntwo\nthree\nfour\nFIVE\n"
  write("file.txt", edited)
  hunks = GitOps.hunks(base, edited)
  assert(#hunks == 2, ("expected two separate hunks, got %d"):format(#hunks))
  local expected = { before = base, after = edited }
  must(sync(GitOps.stage_hunk, root, "file.txt", hunks[1], expected), "staging a hunk failed")
  assert(status_of("file.txt") == "MM", "staging one hunk should leave the other unstaged")
  assert(git({ "show", ":file.txt" }) == "ONE\ntwo\nthree\nfour\nfive\n", "the wrong hunk reached the index")
  assert(read("file.txt") == edited, "staging a hunk must not touch the working tree")

  -- The staged half can be taken back out on its own.
  local head = git({ "show", "HEAD:file.txt" })
  local staged = git({ "show", ":file.txt" })
  local staged_hunks = GitOps.hunks(head, staged)
  assert(#staged_hunks == 1, "expected exactly one staged hunk")
  local sides = { before = head, after = staged }
  must(sync(GitOps.unstage_hunk, root, "file.txt", staged_hunks[1], sides), "unstaging a hunk failed")
  assert(git({ "show", ":file.txt" }) == head, "unstaging the only staged hunk did not clear the index")
  assert(read("file.txt") == edited, "unstaging a hunk must not touch the working tree")

  -- Discarding a hunk rewrites the file and leaves the rest of the edit.
  base = git({ "show", ":file.txt" })
  hunks = GitOps.hunks(base, edited)
  sides = { before = base, after = edited }
  must(sync(GitOps.discard_hunk, root, "file.txt", hunks[1], sides), "discarding a hunk failed")
  assert(read("file.txt") == "one\ntwo\nthree\nfour\nFIVE\n", "discarding a hunk changed the wrong lines")

  -- A hunk is a pair of line ranges: once the file has moved on it points at
  -- the wrong lines, and writing anyway would destroy work.
  local stale = sync(GitOps.stage_hunk, root, "file.txt", hunks[1], { before = base, after = "something else\n" })
  local refused = type(stale) == "string" and stale:find("changed since", 1, true)
  assert(refused, "a stale hunk was applied: " .. tostring(stale))
end)

vim.fn.delete(root, "rf")
assert(ok, test_error)

print("git-ops-ok")
