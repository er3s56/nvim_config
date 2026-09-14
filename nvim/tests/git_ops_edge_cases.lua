local G = require("config.git_ops")
local uv = vim.uv
local base = vim.fn.tempname()
vim.fn.mkdir(base, "p")

local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local file = assert(io.open(path, "wb"))
  assert(file:write(text))
  assert(file:close())
end

local function read(path)
  local file = assert(io.open(path, "rb"))
  local content = file:read("*a")
  file:close()
  return content
end

local function git(root, ...)
  local args = { "git", "-C", root }
  vim.list_extend(args, { ... })
  local result = vim.system(args, { text = false }):wait()
  assert(result.code == 0, table.concat(args, " ") .. ": " .. (result.stderr or ""))
  return result.stdout or ""
end

local function repo(name)
  local root = base .. "/" .. name
  vim.fn.mkdir(root, "p")
  git(root, "init", "-q")
  git(root, "config", "user.name", "Hunk Regression")
  git(root, "config", "user.email", "hunk@example.invalid")
  git(root, "config", "core.autocrlf", "false")
  return root
end

local function commit(root)
  git(root, "add", "--all")
  git(root, "commit", "-qm", "fixture")
end

local function sync(fn, ...)
  local args, done, captured = { ... }, false, nil
  args[#args + 1] = function(err)
    done, captured = true, err
  end
  fn(unpack(args))
  assert(
    vim.wait(5000, function()
      return done
    end),
    "Git operation timed out"
  )
  return captured
end

local function succeeds(fn, ...)
  local err = sync(fn, ...)
  assert(err == nil, err)
end

local function expected(before, after, old)
  return { before = before, after = after, before_path = old }
end

local function index(root, path)
  return git(root, "show", ":" .. path)
end

local function checkout_form(root, path)
  return git(root, "cat-file", "--filters", "--path=" .. path, ":" .. path)
end

local ok, err = xpcall(function()
  -- The diff library and splice arithmetic must agree even at either empty
  -- edge, without a final newline, and across more than one hunk.
  local corpus =
    { "", "\n", "\n\n", "x", "x\n", "\nx\n", "x\n\n", "x\ny", "x\ny\n", "a\nb\nc\nd\ne\n", "A\nb\nc\nd\nE\n" }
  for _, before in ipairs(corpus) do
    for _, after in ipairs(corpus) do
      local hunks = G.hunks(before, after)
      local applied, reverted = before, after
      for i = #hunks, 1, -1 do
        applied = G.apply_hunk(applied, after, hunks[i])
        reverted = G.revert_hunk(before, reverted, hunks[i])
      end
      assert(applied == after, "apply lost bytes: " .. vim.inspect({ before, after, applied, hunks }))
      assert(reverted == before, "revert lost bytes: " .. vim.inspect({ before, after, reverted, hunks }))
    end
  end

  local root = repo("links")
  write(root .. "/old.txt", "old target\n")
  write(root .. "/new.txt", "valuable target\n")
  assert(uv.fs_symlink("old.txt", root .. "/link"))
  commit(root)
  assert(uv.fs_unlink(root .. "/link"))
  assert(uv.fs_symlink("new.txt", root .. "/link"))
  local before, after = index(root, "link"), read(root .. "/new.txt")
  local hunk = assert(G.hunks(before, after)[1])
  for _, operation in ipairs({ G.stage_hunk, G.discard_hunk }) do
    local failure = sync(operation, root, "link", hunk, expected(before, after))
    assert(failure and failure:find("whole-file", 1, true), "a symlink was accepted for a hunk")
    assert(read(root .. "/new.txt") == "valuable target\n", "a symlink target was overwritten")
    assert(index(root, "link") == "old.txt", "symlink blob was replaced by target content")
  end
  git(root, "add", "link")
  assert(sync(G.unstage_hunk, root, "link", G.hunks("old.txt", "new.txt")[1], expected("old.txt", "new.txt")))
  assert(index(root, "link") == "new.txt")
  -- Also reject a type change whose working side has become a regular file.
  assert(uv.fs_unlink(root .. "/link"))
  write(root .. "/link", "regular now\n")
  assert(sync(G.stage_hunk, root, "link", G.hunks("new.txt", "regular now\n")[1], expected("new.txt", "regular now\n")))
  assert(read(root .. "/new.txt") == "valuable target\n")

  root = repo("crlf")
  write(root .. "/.gitattributes", "*.txt text eol=crlf\n")
  local original = "one\r\ntwo\r\nthree\r\nfour\r\nfive\r\nsix\r\nseven\r\n"
  write(root .. "/file.txt", original)
  commit(root)
  after = "ONE\r\ntwo\r\nthree\r\nfour\r\nfive\r\nsix\r\nSEVEN\r\n"
  write(root .. "/file.txt", after)
  before = checkout_form(root, "file.txt")
  local hunks = G.hunks(before, after)
  assert(#hunks == 2, "line endings turned two edits into a whole-file hunk")
  succeeds(G.stage_hunk, root, "file.txt", hunks[1], expected(before, after))
  assert(index(root, "file.txt") == "ONE\ntwo\nthree\nfour\nfive\nsix\nseven\n", "clean rules were bypassed")
  assert(read(root .. "/file.txt") == after, "stage changed the working tree")
  before = checkout_form(root, "file.txt")
  succeeds(G.discard_hunk, root, "file.txt", G.hunks(before, after)[1], expected(before, after))
  assert(read(root .. "/file.txt") == before, "discard changed unrelated CRLF bytes")
  before, after = git(root, "show", "HEAD:file.txt"), index(root, "file.txt")
  succeeds(G.unstage_hunk, root, "file.txt", G.hunks(before, after)[1], expected(before, after))
  assert(index(root, "file.txt") == before, "unstage did not retain canonical LF bytes")

  -- Clean deliberately is not idempotent. Applying it to the index a second
  -- time is observable, unlike an eol-only test.
  root = repo("filter")
  git(root, "config", "filter.prefix.clean", "sed 's/^/stored:/'")
  git(root, "config", "filter.prefix.smudge", "sed 's/^stored://' ")
  git(root, "config", "filter.prefix.required", "true")
  write(root .. "/.gitattributes", "*.txt filter=prefix\n")
  write(root .. "/file.txt", "one\ntwo\nthree\nfour\nfive\n")
  commit(root)
  before = checkout_form(root, "file.txt")
  after = "ONE\ntwo\nthree\nfour\nFIVE\n"
  write(root .. "/file.txt", after)
  succeeds(G.stage_hunk, root, "file.txt", G.hunks(before, after)[1], expected(before, after))
  assert(index(root, "file.txt") == "stored:ONE\nstored:two\nstored:three\nstored:four\nstored:five\n")
  before, after = git(root, "show", "HEAD:file.txt"), index(root, "file.txt")
  succeeds(G.unstage_hunk, root, "file.txt", G.hunks(before, after)[1], expected(before, after))
  assert(index(root, "file.txt") == before, "unstage applied clean twice")

  root = repo("rename")
  before = "one\ntwo\nthree\nfour\nfive\n"
  write(root .. "/old.txt", before)
  commit(root)
  git(root, "mv", "old.txt", "new.txt")
  after = "one\nTWO\nthree\nfour\nfive\n"
  write(root .. "/new.txt", after)
  git(root, "add", "new.txt")
  succeeds(G.unstage_hunk, root, "new.txt", G.hunks(before, after)[1], expected(before, after, "old.txt"))
  assert(index(root, "new.txt") == before, "rename edit could not be unstaged")
  assert(read(root .. "/new.txt") == after, "unstaging edited the worktree")
  assert(git(root, "ls-files", "--", "old.txt") == "", "unstaging a content hunk undid the rename")

  root = repo("deletion")
  write(root .. "/script.sh", "#!/bin/sh\necho hello\n")
  assert(uv.fs_chmod(root .. "/script.sh", 493))
  commit(root)
  before = index(root, "script.sh")
  assert(uv.fs_unlink(root .. "/script.sh"))
  hunk = G.hunks(before, "")[1]
  succeeds(G.discard_hunk, root, "script.sh", hunk, expected(before, ""))
  assert(read(root .. "/script.sh") == before)
  assert(uv.fs_access(root .. "/script.sh", "X"), "restoring deletion lost the executable bit")
  assert(uv.fs_unlink(root .. "/script.sh"))
  succeeds(G.stage_hunk, root, "script.sh", hunk, expected(before, ""))
  assert(git(root, "ls-files", "--", "script.sh") == "", "staging deletion left an empty indexed file")
  succeeds(G.unstage_hunk, root, "script.sh", hunk, expected(before, ""))
  assert(index(root, "script.sh") == before)
  assert(git(root, "ls-files", "--stage", "--", "script.sh"):match("^100755"), "unstaging deletion lost mode")

  -- Both an existing repository and an unborn one can unstage a new file.
  for _, unborn in ipairs({ false, true }) do
    root = repo("new-" .. tostring(unborn))
    if not unborn then
      write(root .. "/existing", "initial\n")
      commit(root)
    end
    after = "new content\n"
    write(root .. "/new.txt", after)
    succeeds(G.stage_hunk, root, "new.txt", G.hunks("", after)[1], expected("", after))
    succeeds(G.unstage_hunk, root, "new.txt", G.hunks("", after)[1], expected("", after))
    assert(git(root, "ls-files", "--", "new.txt") == "", "unstaging new file left an empty indexed file")
    assert(read(root .. "/new.txt") == after)
  end
end, debug.traceback)

vim.fn.delete(base, "rf")
assert(ok, err)
print("git-ops-edge-cases-ok")
