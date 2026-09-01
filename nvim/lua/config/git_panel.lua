local ContextMenu = require("config.context_menu")
local GitOps = require("config.git_ops")
local PanelLayout = require("config.panel_layout")
local TerminalTabs = require("config.terminal_tabs")

local M = {}

-- The commit list grows as it is scrolled rather than loading the whole
-- history: `git log` over a large repository is measured at 11s and 110MB of
-- output for a million commits, which would also mean a million-line buffer.
local COMMIT_BATCH = 200
local states = {}
local load_commits
local drop_stale_worktree_preview
local reload_preview
local ns = vim.api.nvim_create_namespace("project_git_panel")
-- The hunk buttons live in the diff buffers, which the panel does not own the
-- highlights of, so they get a namespace that can be cleared on its own.
local hunk_ns = vim.api.nvim_create_namespace("project_git_panel_hunks")
local resize_generation = 0
local reflowing_layout = false
local explorer_preferred_widths = setmetatable({}, { __mode = "k" })
local git_panel_placements = {}
-- How much history each repository had expanded, kept across panel instances.
-- Activity Bar destroys and rebuilds the panel on every view switch, so
-- without this a list the user grew with Load More would snap back to the
-- first batch as soon as they looked at the Explorer and came back.
local commit_depths = {}

local function placement_key(root, tab)
  return root .. "\0" .. tostring(tab)
end

local function valid(state)
  return state and vim.api.nvim_buf_is_valid(state.buf) and vim.api.nvim_win_is_valid(state.win)
end

local function run(cmd, callback, text)
  vim.system(cmd, { text = text ~= false }, function(result)
    vim.schedule(function()
      callback(result.code == 0 and (result.stdout or "") or "", result.code, result.stderr or "")
    end)
  end)
end

local function run_git(root, args, callback, text)
  local cmd = { "git", "--no-optional-locks", "-C", root }
  vim.list_extend(cmd, args)
  run(cmd, callback, text)
end

local function notify_error(message)
  if rawget(_G, "Snacks") and Snacks.notify then
    Snacks.notify.error(message)
  else
    vim.notify(message, vim.log.levels.ERROR)
  end
end

local function display_path(path, width)
  local text = (path or ""):gsub("[\r\n]", " ")
  width = math.max(width or 0, 0)
  if width == 0 then
    return ""
  end
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  if width == 1 then
    return "…"
  end

  local budget = width - 1
  local start = vim.fn.strchars(text)
  local used = 0
  while start > 0 do
    local char = vim.fn.strcharpart(text, start - 1, 1)
    local char_width = vim.fn.strdisplaywidth(char)
    if char_width > 0 and used + char_width > budget then
      break
    end
    used = used + char_width
    start = start - 1
  end
  return "…" .. vim.fn.strcharpart(text, start)
end

local function truncate(text, width)
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  return vim.fn.strcharpart(text, 0, math.max(width - 1, 1)) .. "…"
end

-- Rows show one letter per group, commits show git's own code, so this has to
-- read both. Untracked is `??` in git's output and `U` on a row; they mean the
-- same thing to the eye and get the same colour.
local function status_hl(status)
  return status:find("[?U]") and "DiagnosticInfo"
    or status:find("D", 1, true) and "DiagnosticError"
    or status:find("M", 1, true) and "DiagnosticWarn"
    or "Special"
end

-- The actions a row offers, in the order VSCode lays them out. Destructive
-- first is deliberate: acting on a row changes which buttons it has, and the
-- button that slides under a pointer already on its way down must never be the
-- one that throws work away.
local ROW_ACTIONS = {
  { action = "discard", glyph = "↺", label = "Discard Changes", all = "Discard All Changes" },
  { action = "unstage", glyph = "−", label = "Unstage Changes", all = "Unstage All Changes" },
  { action = "stage", glyph = "+", label = "Stage Changes", all = "Stage All Changes" },
}

-- The groups VSCode splits its changes into, in its order. A file that is both
-- staged and modified gets a row in each of the last two: the index and the
-- working tree hold different versions of it, and each version is staged,
-- discarded and diffed on its own.
local SECTIONS = {
  { section = "merge", title = "MERGE CHANGES" },
  { section = "staged", title = "STAGED CHANGES" },
  { section = "changes", title = "CHANGES" },
}

local SECTION_TITLES = {}
for _, group in ipairs(SECTIONS) do
  SECTION_TITLES[group.section] = group.title
end

local function changes_in(state, section)
  local rows = {}
  for _, change in ipairs(state.changes or {}) do
    if change.group == section then
      rows[#rows + 1] = change
    end
  end
  return rows
end

local function change_actions(changes)
  local allowed = { stage = false, unstage = false, discard = false }
  for _, change in ipairs(changes or {}) do
    local actions = GitOps.file_actions(change.status, change.group)
    allowed.stage = allowed.stage or actions.stage
    allowed.unstage = allowed.unstage or actions.unstage
    allowed.discard = allowed.discard or actions.discard
  end
  return allowed
end

-- What a row can do, and to how much. A section header acts on every change
-- under it, except that it never offers to discard: a single click that throws
-- away every uncommitted edit in the tree is not a button this panel grows.
local function entry_actions(state, entry)
  if not entry then
    return nil
  end
  if entry.kind == "worktree_file" then
    return GitOps.file_actions(entry.status, entry.group), "file"
  end
  if entry.kind == "section" and SECTION_TITLES[entry.section] then
    local rows = changes_in(state, entry.section)
    if rows[1] then
      local allowed = change_actions(rows)
      allowed.discard = false
      return allowed, "all"
    end
  end
end

local function entry_buttons(state, entry)
  local allowed, scope = entry_actions(state, entry)
  local buttons = {}
  for _, action in ipairs(allowed and ROW_ACTIONS or {}) do
    if allowed[action.action] then
      buttons[#buttons + 1] = {
        action = action.action,
        glyph = action.glyph,
        label = scope == "all" and action.all or action.label,
        scope = scope,
      }
    end
  end
  return buttons
end

local function section_text(state, section)
  local arrow = state.collapsed[section] and "▸" or "▾"
  if SECTION_TITLES[section] then
    local label = state.changes == nil and "loading…" or tostring(#changes_in(state, section))
    return ("  %s %s  %s"):format(arrow, SECTION_TITLES[section], label)
  end
  if section == "timeline" then
    -- The header names the file, the way VSCode's Timeline follows the active
    -- editor: a list of commits means nothing without knowing whose they are.
    local timeline = state.timeline or {}
    local label = "no file"
    if timeline.path then
      label = vim.fs.basename(timeline.path)
      if timeline.commits == nil then
        label = label .. "  loading…"
      end
    end
    return ("  %s TIMELINE  %s"):format(arrow, label)
  end
  local label = state.commits == nil and "loading…" or tostring(#state.commits)
  return ("  %s COMMITS  %s"):format(arrow, label)
end

local function row_highlight(entry)
  if entry.kind == "section" then
    return "Function"
  end
  -- A conflict is not the colour of whichever letter its code happens to hold:
  -- `DU` is not a deletion and `AA` is not an addition.
  if entry.group == "merge" then
    return "DiagnosticError"
  end
  return status_hl(entry.letter or entry.status)
end

local function pad_display(text, width)
  local padding = width - vim.fn.strdisplaywidth(text)
  return padding > 0 and text .. string.rep(" ", padding) or text
end

-- One row of the panel, with its action strip when it is the row that carries
-- the buttons. The strip's byte ranges come back with it: a click reports a
-- byte column, and nothing else can say which button it landed on.
local function build_row(state, entry, width, with_buttons)
  local buttons = with_buttons and entry_buttons(state, entry) or {}
  local strip = ""
  for _, button in ipairs(buttons) do
    strip = strip .. " " .. button.glyph
  end
  local available = math.max(width - vim.fn.strdisplaywidth(strip), 1)

  local text
  if entry.kind == "section" then
    text = section_text(state, entry.section)
  else
    local prefix = ("  %-2s "):format(entry.letter or entry.status)
    text = prefix .. display_path(entry.path, math.max(available - vim.fn.strdisplaywidth(prefix), 1))
  end
  if #buttons == 0 then
    return text, nil
  end

  text = pad_display(text, available)
  local ranges, column = {}, #text
  for _, button in ipairs(buttons) do
    local piece = " " .. button.glyph
    ranges[#ranges + 1] = {
      from = column + 1,
      to = column + #piece,
      action = button.action,
      label = button.label,
      scope = button.scope,
      entry = entry,
    }
    column = column + #piece
  end
  return text .. strip, ranges
end

-- Which row shows its buttons. VSCode reveals them under the pointer; a
-- terminal reports pointer movement only where 'mousemoveevent' works, so the
-- cursor row -- which every click, drag and keypress already moves -- stands in
-- when it does not.
local function active_row(state)
  if state.hover_line then
    return state.hover_line
  end
  if vim.api.nvim_win_is_valid(state.win) then
    return vim.api.nvim_win_get_cursor(state.win)[1]
  end
end

local function apply_button_highlights(state, line, ranges)
  for _, range in ipairs(ranges or {}) do
    local column = state.hover_line == line and state.hover_column or nil
    local hovered = column ~= nil and column >= range.from and column <= range.to
    vim.api.nvim_buf_set_extmark(state.buf, ns, line - 1, range.from - 1, {
      end_col = range.to,
      hl_group = hovered and "PmenuSel" or "Special",
      -- Above the row's own colour, which spans the whole line.
      priority = 200,
    })
  end
end

local function render(state)
  if not valid(state) then
    return
  end

  local width = vim.api.nvim_win_get_width(state.win)
  local cursor = vim.api.nvim_win_get_cursor(state.win)
  local active = active_row(state)
  local lines, entries, highlights, buttons = {}, {}, {}, {}

  local function add(text, highlight, entry)
    lines[#lines + 1] = text
    if highlight then
      highlights[#highlights + 1] = { #lines - 1, highlight }
    end
    if entry then
      entries[#lines] = entry
    end
  end

  -- Rows that carry actions go through build_row(), so redrawing one row on
  -- its own produces exactly the text a full render would have given it.
  local function add_row(entry)
    local text, ranges = build_row(state, entry, width, #lines + 1 == active)
    add(text, row_highlight(entry), entry)
    if ranges then
      buttons[#lines] = ranges
    end
  end

  add("   " .. (state.branch or "Git"), "Title")
  -- The buttons only appear on one row at a time, so the hint has to point at
  -- the menu: it is the one place every action is always listed.
  add("  click/↵ open · right-click menu", "NonText")
  for _, group in ipairs(SECTIONS) do
    local rows = changes_in(state, group.section)
    -- An empty group is not a group: VSCode shows Merge Changes and Staged
    -- Changes only once something is in them. CHANGES stays whatever happens,
    -- because a clean working tree still has to be told somewhere.
    if #rows > 0 or group.section == "changes" then
      add("")
      add_row({ kind = "section", section = group.section })
      if not state.collapsed[group.section] and state.changes ~= nil then
        if #rows == 0 then
          add("    ✓ Working tree clean", "DiagnosticOk")
        end
        for _, item in ipairs(rows) do
          add_row(item)
        end
      end
    end
  end

  add("")
  add_row({ kind = "section", section = "commits" })
  if not state.collapsed.commits and state.commits ~= nil then
    if #state.commits == 0 then
      add("    No commits", "Comment")
    end
    for _, commit in ipairs(state.commits) do
      local expanded = state.expanded[commit.full_hash]
      add(
        ("  %s %s %s"):format(
          expanded and "▾" or "▸",
          commit.hash,
          truncate(commit.subject, math.max(width - 15, 10))
        ),
        nil,
        commit
      )

      if expanded then
        local cached = state.commit_files[commit.full_hash]
        if not cached or cached.loading then
          add("      loading changed files…", "Comment")
        elseif cached.error then
          add("      Failed to load changed files", "DiagnosticError")
        elseif #cached.files == 0 then
          add("      No changed files", "Comment")
        else
          for _, file in ipairs(cached.files) do
            local prefix = ("    %-4s "):format(file.status)
            add(
              prefix .. display_path(file.path, math.max(width - vim.fn.strdisplaywidth(prefix), 1)),
              status_hl(file.status),
              file
            )
          end
        end
      end
    end
    -- The history is loaded a batch at a time and stops there. Reaching the
    -- end of the list is a deliberate pause with an explicit entry, rather
    -- than history that keeps growing under the scroll.
    if not state.commits_exhausted and #state.commits > 0 then
      if state.commit_loading then
        add("    Loading more commits…", "Comment", { kind = "commit_load_more", loading = true })
      else
        add("  ↓ Load more commits", "Function", { kind = "commit_load_more" })
      end
    end
  end

  -- The history of the file being edited, the way VSCode's Timeline follows
  -- the active editor. Its rows are commit diffs of one file, so clicking one
  -- opens exactly what a file under an expanded commit does.
  add("")
  add_row({ kind = "section", section = "timeline" })
  local timeline = state.timeline or {}
  if not state.collapsed.timeline then
    if not timeline.path then
      add("    No file in the editor", "Comment")
    elseif timeline.commits == nil then
      add("    Loading history…", "Comment")
    elseif #timeline.commits == 0 then
      add("    No history for this file", "Comment")
    else
      for _, commit in ipairs(timeline.commits) do
        add(
          ("  %s %s"):format(commit.short_hash, truncate(commit.subject, math.max(width - 13, 10))),
          nil,
          commit
        )
      end
      if not timeline.exhausted then
        if timeline.loading then
          add("    Loading more history…", "Comment", { kind = "timeline_load_more", loading = true })
        else
          add("  ↓ Load more history", "Function", { kind = "timeline_load_more" })
        end
      end
    end
  end

  state.entries = entries
  state.buttons = buttons
  state.active_line = active
  -- Appending a batch leaves every earlier line untouched, so replace only the
  -- tail that actually changed. Rewriting the whole buffer costs seconds once
  -- the list is thousands of lines long, and it scrolls the viewport away from
  -- where the reader left it.
  local previous = state.rendered_lines or {}
  local shared = 0
  while shared < #lines and shared < #previous and lines[shared + 1] == previous[shared + 1] do
    shared = shared + 1
  end
  local view
  if vim.api.nvim_win_is_valid(state.win) then
    view = vim.api.nvim_win_call(state.win, vim.fn.winsaveview)
  end
  vim.bo[state.buf].modifiable = true
  if shared > 0 and shared == #previous and #lines > #previous then
    -- Pure append: only the new tail is written.
    vim.api.nvim_buf_set_lines(state.buf, shared, -1, false, vim.list_slice(lines, shared + 1))
  else
    vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
    vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
    shared = 0
  end
  for index, item in ipairs(highlights) do
    if item[1] >= shared then
      vim.api.nvim_buf_add_highlight(state.buf, ns, item[2], item[1], 0, -1)
    end
    local _ = index
  end
  for line, ranges in pairs(buttons) do
    if line - 1 >= shared then
      apply_button_highlights(state, line, ranges)
    end
  end
  state.rendered_lines = lines
  vim.bo[state.buf].modifiable = false
  pcall(vim.api.nvim_win_set_cursor, state.win, { math.min(cursor[1], #lines), 0 })
  if view then
    pcall(vim.api.nvim_win_call, state.win, function()
      view.lnum = math.min(view.lnum, #lines)
      view.topline = math.min(view.topline, #lines)
      vim.fn.winrestview(view)
    end)
  end
end

-- Redraw one row in place. Moving the action strip touches only the row the
-- pointer left and the one it entered, and a full render rewrites every line
-- of a list that can be thousands of commits long -- far too much work to do
-- on a mouse movement.
local function render_row(state, line)
  if not valid(state) or not line or not state.rendered_lines then
    return
  end
  local entry = state.entries and state.entries[line]
  if not entry or not entry_actions(state, entry) then
    return
  end
  local text, ranges = build_row(state, entry, vim.api.nvim_win_get_width(state.win), line == active_row(state))
  state.buttons = state.buttons or {}
  state.buttons[line] = ranges
  if state.rendered_lines[line] ~= text then
    vim.bo[state.buf].modifiable = true
    vim.api.nvim_buf_set_lines(state.buf, line - 1, line, false, { text })
    vim.bo[state.buf].modifiable = false
    state.rendered_lines[line] = text
  end
  vim.api.nvim_buf_clear_namespace(state.buf, ns, line - 1, line)
  vim.api.nvim_buf_add_highlight(state.buf, ns, row_highlight(entry), line - 1, 0, -1)
  apply_button_highlights(state, line, ranges)
end

-- Hand the action strip to whichever row is active now.
local function follow_active_row(state)
  if not valid(state) then
    return
  end
  local current = active_row(state)
  if state.active_line == current then
    return
  end
  local previous = state.active_line
  state.active_line = current
  render_row(state, previous)
  render_row(state, current)
end

-- Where a status puts its file, and what the row shows there. Each group is
-- about one column of git's two-letter code, so a row shows the column its own
-- group is about rather than repeating both -- except a conflict, where both
-- letters carry state and neither reading applies.
--
-- Staged comes first so that a diff whose group later empties out falls back
-- to the index side of the file rather than to whatever else is left of it.
local function status_rows(status, path, old_path)
  local base = { kind = "worktree_file", status = status, path = path, old_path = old_path }
  local function row(group, letter)
    return vim.tbl_extend("force", base, { group = group, letter = letter })
  end
  if GitOps.is_unmerged(status) then
    return { row("merge", status) }
  end
  if status == "??" then
    return { row("changes", "U") }
  end
  local rows = {}
  local index, worktree = status:sub(1, 1), status:sub(2, 2)
  if index ~= " " and index ~= "" then
    rows[#rows + 1] = row("staged", index)
  end
  if worktree ~= " " and worktree ~= "" then
    rows[#rows + 1] = row("changes", worktree)
  end
  return rows
end

local function parse_status(output)
  local branch = "Git"
  local changes = {}
  local records = vim.split(output, "\0", { plain = true, trimempty = true })
  local index = 1
  while index <= #records do
    local record = records[index]
    if record:sub(1, 3) == "## " then
      branch = record:sub(4):gsub("%.%.%..*$", "")
    elseif #record >= 4 then
      local status = record:sub(1, 2)
      local path = record:sub(4)
      local renamed = status:find("R", 1, true) or status:find("C", 1, true)
      local old_path
      if renamed then
        index = index + 1
        old_path = records[index]
      end
      vim.list_extend(changes, status_rows(status, path, old_path))
    end
    index = index + 1
  end
  return branch, changes
end

-- Append the next slice of history, or reload the first `count` commits when
-- `reset` is set. Guarded by the same generation counter as a full refresh, so
-- a slice that arrives after the panel moved on is discarded.
function load_commits(state, opts)
  opts = opts or {}
  if not valid(state) or state.commit_loading then
    return
  end
  if not opts.reset and state.commits_exhausted then
    return
  end
  local skip = opts.reset and 0 or state.commit_offset
  local count = opts.count or COMMIT_BATCH
  -- Ask for one commit beyond what is wanted. A full request is otherwise
  -- ambiguous -- it can mean "there is more" or "that was the whole history"
  -- -- and guessing either way is wrong: guessing "more" leaves a Load More
  -- entry that does nothing, guessing "done" hides commits that arrive later.
  local probe = count + 1
  state.commit_loading = true
  state.commit_generation = state.commit_generation + 1
  local commit_generation = state.commit_generation
  run_git(state.root, {
    "log",
    "--pretty=format:%H%x09%h%x09%s",
    ("--skip=%d"):format(skip),
    ("-n%d"):format(probe),
  }, function(output)
    if not valid(state) or state.commit_generation ~= commit_generation then
      state.commit_loading = false
      return
    end
    local batch = {}
    for line in output:gmatch("[^\r\n]+") do
      local full_hash, hash, subject = line:match("^([^\t]+)\t([^\t]+)\t(.*)$")
      if full_hash and hash and subject then
        batch[#batch + 1] = {
          kind = "commit",
          full_hash = full_hash,
          hash = hash,
          subject = subject,
        }
      end
    end
    -- The extra commit is only a probe; it never enters the list.
    local exhausted = #batch <= count
    batch[count + 1] = nil
    if opts.reset then
      state.commits = {}
    end
    state.commits = state.commits or {}
    for _, commit in ipairs(batch) do
      state.commits[#state.commits + 1] = commit
    end
    state.commit_offset = #state.commits
    state.commits_exhausted = exhausted
    commit_depths[state.root] = {
      offset = state.commit_offset,
      exhausted = state.commits_exhausted,
    }
    state.commit_loading = false
    render(state)
  end)
end

-- One page of a file's history. `--follow` is what makes it a timeline rather
-- than a log of a name: the file's story does not begin where its current path
-- does, and `--name-status` gives each commit its own view of the path so the
-- diff of a commit from before a rename can still be asked for.
--
-- It also rules out paging with `--skip`. Following a rename rewrites the path
-- as the walk goes, and git answers a skipped `--follow` with nothing at all,
-- so a longer page is re-read from the top instead. For the history of a single
-- file that is a cheap thing to do.
local TIMELINE_BATCH = 50

local function parse_timeline(output, path)
  local commits, current = {}, nil
  for line in output:gmatch("[^\r\n]+") do
    local hash, short, subject = line:match("^(%x+)\t(%x+)\t(.*)$")
    if hash and #hash == 40 then
      current = {
        kind = "commit_file",
        commit = hash,
        short_hash = short,
        subject = subject,
        status = "M",
        path = path,
      }
      commits[#commits + 1] = current
    elseif current then
      local status, first, second = line:match("^(%u%d*)\t([^\t]+)\t?(.*)$")
      if status then
        current.status = status:sub(1, 1)
        if second ~= "" then
          current.old_path, current.path = first, second
        else
          current.path = first
        end
      end
    end
  end
  return commits
end

local function load_timeline(state, opts)
  opts = opts or {}
  local timeline = state.timeline
  if not valid(state) or not timeline or not timeline.path then
    return
  end
  local count = opts.count or (#(timeline.commits or {}) + TIMELINE_BATCH)
  -- Once the whole history is on screen there is nothing left to grow into,
  -- so only a refresh (`force`) re-reads it.
  if timeline.loading or (timeline.exhausted and not opts.force) then
    return
  end
  local path = timeline.path
  timeline.loading = true
  timeline.generation = timeline.generation + 1
  local generation = timeline.generation
  run_git(state.root, {
    "-c",
    "core.quotepath=false",
    "log",
    "--follow",
    "--name-status",
    "-M",
    "--pretty=format:%H\t%h\t%s",
    -- One past the page, so "a full page" and "the end of the history" can be
    -- told apart the way the commit list does it.
    ("-n%d"):format(count + 1),
    "--",
    path,
  }, function(output)
    if not valid(state) or timeline.generation ~= generation or timeline.path ~= path then
      timeline.loading = false
      return
    end
    local batch = parse_timeline(output, path)
    timeline.exhausted = #batch <= count
    batch[count + 1] = nil
    timeline.commits = batch
    timeline.offset = #batch
    timeline.loading = false
    render(state)
  end)
end

-- The file the timeline follows is whatever the editor is showing. A panel, a
-- terminal or a diff is not a file, and moving focus into one of them is no
-- reason to throw the history away.
local function buffer_repository_path(state, buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "" then
    return
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    return
  end
  local full = vim.fs.normalize(vim.fn.fnamemodify(name, ":p"))
  local root = (vim.fs.normalize(state.root or "")):gsub("/$", "")
  if root == "" or full:sub(1, #root + 1) ~= root .. "/" then
    return
  end
  return full:sub(#root + 2)
end

local function editor_file_path(state)
  -- The focused buffer first, then any file the tab is showing: clicking into
  -- the panel must not count as "no file open", and neither must a diff.
  local path = buffer_repository_path(state, vim.api.nvim_get_current_buf())
  if path then
    return path
  end
  if not vim.api.nvim_win_is_valid(state.win) then
    return
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(state.win))) do
    path = buffer_repository_path(state, vim.api.nvim_win_get_buf(win))
    if path then
      return path
    end
  end
end

local function sync_timeline(state, opts)
  if not valid(state) or not state.timeline then
    return
  end
  local timeline = state.timeline
  local path = editor_file_path(state)
  local switched = path ~= nil and path ~= timeline.path
  if switched then
    timeline.path = path
    timeline.commits = nil
    timeline.offset = 0
    timeline.exhausted = false
    render(state)
  elseif not timeline.path or not (opts and opts.reload) then
    return
  end
  -- Keep as much history as was already on screen, so a list the reader grew
  -- does not snap back to the first page behind a new commit.
  load_timeline(state, { force = true, count = math.max(TIMELINE_BATCH, switched and 0 or timeline.offset) })
end

local timeline_tracking_set = false

local function setup_timeline_tracking()
  if timeline_tracking_set then
    return
  end
  timeline_tracking_set = true
  local group = vim.api.nvim_create_augroup("project_git_panel_timeline", { clear = true })
  vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, {
    group = group,
    callback = function()
      for buf, state in pairs(states) do
        if not valid(state) then
          states[buf] = nil
        else
          sync_timeline(state)
        end
      end
    end,
  })
end

function M.refresh(buf, opts)
  local state = states[buf]
  if not valid(state) then
    return
  end
  opts = opts or {}

  state.status_generation = state.status_generation + 1
  local status_generation = state.status_generation
  if not opts.status_only then
    state.changes = nil
    state.commits = nil
    state.commits_exhausted = false
    render(state)
  end

  run_git(state.root, {
    "-c",
    "core.quotepath=false",
    "status",
    "--porcelain=v1",
    "-z",
    "--branch",
    "--untracked-files=all",
  }, function(output)
    if not valid(state) or state.status_generation ~= status_generation then
      return
    end
    state.branch, state.changes = parse_status(output)
    drop_stale_worktree_preview(state)
    render(state)
  end, false)

  if opts.status_only then
    return
  end

  -- Reload as many commits as were already on screen, so a refresh triggered
  -- by a commit or a checkout does not yank the list back to the first batch
  -- while it is being scrolled.
  local remembered = commit_depths[state.root]
  local depth = math.max(COMMIT_BATCH, state.commit_offset, remembered and remembered.offset or 0)
  load_commits(state, { count = depth, reset = true })
  sync_timeline(state, { reload = true })
end

local function current_state()
  for buf, state in pairs(states) do
    if not valid(state) then
      states[buf] = nil
    elseif vim.api.nvim_win_get_tabpage(state.win) == vim.api.nvim_get_current_tabpage() then
      return state
    end
  end
end

local function default_git_height(left_content_height)
  if left_content_height then
    return math.max(1, math.floor(left_content_height / 2))
  end
  return math.min(20, math.max(10, math.floor(math.max(vim.o.lines - 2, 1) * 0.23)))
end

local function explorer_has_buffer(explorer, buffer)
  local windows = {
    explorer.list and explorer.list.win,
    explorer.input and explorer.input.win,
    explorer.preview and explorer.preview.win,
    explorer.layout and explorer.layout.root,
  }
  for _, window in ipairs(windows) do
    if window and window.buf == buffer then
      return true
    end
  end
  return false
end

local function disable_explorer_quit(explorer)
  if not explorer then
    return
  end

  local windows = {
    explorer.list and explorer.list.win,
    explorer.input and explorer.input.win,
    explorer.preview and explorer.preview.win,
    explorer.layout and explorer.layout.root,
  }
  for _, window in ipairs(windows) do
    local buffer = window and window.buf
    if buffer and vim.api.nvim_buf_is_valid(buffer) then
      for _, key in ipairs({ "q", "<Esc>" }) do
        vim.keymap.set("n", key, "<Nop>", {
          buffer = buffer,
          silent = true,
          desc = "Disabled in project panels",
        })
      end
      vim.keymap.set("x", ":", "<Esc>:", {
        buffer = buffer,
        silent = false,
        desc = "Open command line without a visual range",
      })
    end
  end
end

local activate_preview

local function valid_preview(preview)
  return preview
    and preview.bufs
    and vim.api.nvim_buf_is_valid(preview.bufs[1])
    and vim.api.nvim_buf_is_valid(preview.bufs[2])
end

local function preview_containing_buffer(state, buf)
  for _, preview in pairs(state.previews or {}) do
    if valid_preview(preview) and vim.tbl_contains(preview.bufs, buf) then
      return preview
    end
  end
end

local function preview_for_buffer(state, buf)
  for _, preview in pairs(state.previews or {}) do
    if valid_preview(preview) and preview.bufs[2] == buf then
      return preview
    end
  end
end

local function capture_editor_context(win, buf)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  buf = buf or vim.api.nvim_win_get_buf(win)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  return {
    buf = buf,
    view = vim.api.nvim_win_call(win, vim.fn.winsaveview),
    options = {
      cursorbind = vim.wo[win].cursorbind,
      cursorline = vim.wo[win].cursorline,
      foldenable = vim.wo[win].foldenable,
      number = vim.wo[win].number,
      relativenumber = vim.wo[win].relativenumber,
      scrollbind = vim.wo[win].scrollbind,
      winbar = vim.wo[win].winbar,
      wrap = vim.wo[win].wrap,
    },
  }
end

local function save_preview_views(state)
  local preview, layout = state.preview, state.preview_layout
  if not valid_preview(preview) or not layout then
    return
  end
  preview.views = preview.views or {}
  for index, win in ipairs({ layout.main_win, layout.after_win }) do
    if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == preview.bufs[index] then
      preview.views[index] = vim.api.nvim_win_call(win, vim.fn.winsaveview)
    end
  end
end

local function restore_window_options(win, options)
  if not options or not win or not vim.api.nvim_win_is_valid(win) then
    return
  end
  for option, value in pairs(options) do
    pcall(function()
      vim.wo[win][option] = value
    end)
  end
end

-- Remove the two-window diff layout but keep all Git diff buffers listed in
-- Bufferline. This makes switching to a normal file behave like changing tabs.
local function hide_preview(state, target_buf, restore_original)
  local layout = state and state.preview_layout
  if not layout then
    return
  end

  state.updating_preview = true
  save_preview_views(state)
  local active_preview = state.preview
  if
    active_preview
    and not active_preview.deleting
    and vim.api.nvim_win_is_valid(layout.main_win)
    and vim.api.nvim_win_is_valid(layout.after_win)
  then
    active_preview.layout_placement = {
      snapshot = PanelLayout.capture(layout.after_win),
      after_win = layout.after_win,
    }
  end
  for _, win in ipairs({ layout.main_win, layout.after_win }) do
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_call, win, function()
        vim.cmd("diffoff")
      end)
    end
  end

  local context = layout.editor_context
  if not target_buf and restore_original and context then
    target_buf = context.buf
  end
  if target_buf and not vim.api.nvim_buf_is_valid(target_buf) then
    target_buf = nil
  end

  local main_win = layout.main_win
  if
    (not main_win or not vim.api.nvim_win_is_valid(main_win))
    and layout.after_win
    and vim.api.nvim_win_is_valid(layout.after_win)
  then
    main_win = layout.after_win
  end
  if main_win and vim.api.nvim_win_is_valid(main_win) and target_buf then
    vim.api.nvim_win_set_buf(main_win, target_buf)
  end
  if layout.after_win and layout.after_win ~= main_win and vim.api.nvim_win_is_valid(layout.after_win) then
    vim.api.nvim_win_close(layout.after_win, true)
  end

  if main_win and vim.api.nvim_win_is_valid(main_win) then
    restore_window_options(main_win, context and context.options)
    if restore_original and context and target_buf == context.buf and context.view then
      pcall(vim.api.nvim_win_call, main_win, function()
        vim.fn.winrestview(context.view)
      end)
    end
    vim.w[main_win].snacks_main = true
    state.editor_win = main_win
    if state.explorer and not state.explorer.closed then
      state.explorer.main = main_win
    end
  end

  state.preview = nil
  state.preview_layout = nil
  state.updating_preview = false
end

local function delete_preview(state, preview)
  if not preview or preview.deleting then
    return
  end
  preview.deleting = true
  if state.preview == preview then
    hide_preview(state, nil, true)
  end
  if state.previews then
    state.previews[preview.key] = nil
  end
  for _, buf in ipairs(preview.bufs or {}) do
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
end

local function close_preview(state)
  if not state then
    return
  end
  state.preview_generation = state.preview_generation + 1
  state.preview_request_key = nil
  state.preview_request_focus = nil
  hide_preview(state, nil, true)

  local previews = {}
  for _, preview in pairs(state.previews or {}) do
    previews[#previews + 1] = preview
  end
  for _, preview in ipairs(previews) do
    delete_preview(state, preview)
  end
end

local function content_lines(content)
  if content:find("\0", 1, true) then
    return { "Binary file — textual preview is unavailable." }
  end
  content = content:gsub("\r\n", "\n")
  local lines = vim.split(content, "\n", { plain = true })
  if #lines > 1 and lines[#lines] == "" then
    table.remove(lines)
  end
  return #lines > 0 and lines or { "" }
end

local function set_preview_content(buf, path, content)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, content_lines(content))
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = vim.filetype.match({ filename = path }) or ""
end

local function update_preview_buffer(buf, name, path, content)
  vim.api.nvim_buf_set_name(buf, name)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].undolevels = -1
  -- Keep Snacks Explorer from treating this nofile buffer as a missing main
  -- editor and selecting the Git panel or terminal as its replacement.
  vim.b[buf].snacks_main = true
  set_preview_content(buf, path, content)
end

local function preview_buffer(listed, name, path, content)
  local buf = vim.api.nvim_create_buf(listed, true)
  update_preview_buffer(buf, name, path, content)
  return buf
end

-- Which row of which file, for the previews keyed by it. A file that is both
-- staged and modified has two rows, and they are two different diffs.
local function row_key(entry)
  return (entry.path or "") .. "\0" .. (entry.group or "")
end

local function entry_key(entry)
  return table.concat({
    entry.kind or "file",
    entry.group or "",
    entry.commit or "worktree",
    entry.status or "",
    entry.old_path or "",
    entry.path or "",
  }, "\0")
end

-- A worktree diff describes how a file currently differs from the index or
-- HEAD. Once the file stops being a change -- staged, reverted, committed,
-- deleted -- that difference no longer exists, but the preview stays on
-- screen showing it, next to a CHANGES list that now says the tree is clean.
--
-- Only worktree previews go stale this way. A commit's contents do not
-- change, so a commit diff stays valid however the working tree moves.
function drop_stale_worktree_preview(state)
  local live, by_row, by_path = {}, {}, {}
  for _, change in ipairs(state.changes or {}) do
    live[entry_key(change)] = true
    by_row[row_key(change)] = change
    -- Staged rows are built first, so a diff whose own group has emptied out
    -- falls back to the index side of the file rather than away from it.
    by_path[change.path] = by_path[change.path] or change
  end
  -- Cached previews are reconciled too, not just the visible one: the cache is
  -- keyed by entry, so a file that comes back with the same status would
  -- otherwise be served its old contents out of it.
  local stale, surviving = {}, {}
  for key, preview in pairs(state.previews or {}) do
    local entry = preview.entry
    if entry and entry.kind == "worktree_file" then
      local replacement = by_row[row_key(entry)] or by_path[entry.path]
      if replacement then
        surviving[#surviving + 1] = { preview = preview, key = key, entry = replacement, moved = not live[key] }
      else
        stale[#stale + 1] = preview
      end
    end
  end
  for _, preview in ipairs(stale) do
    delete_preview(state, preview)
  end
  for _, item in ipairs(surviving) do
    -- Staging one hunk of a modified file moves it from " M" to "MM", which is
    -- a different entry and so a different key -- and staging the whole file
    -- moves the diff into the staged group. Re-key and re-read rather than
    -- closing: VSCode leaves the diff editor open across a staged hunk, and the
    -- window the reader is working in has no business disappearing under them.
    if item.moved then
      state.previews[item.key] = nil
      item.preview.key = entry_key(item.entry)
      state.previews[item.preview.key] = item.preview
    end
    reload_preview(state, item.preview, item.entry)
  end
end

local function diff_edge_filler(win, direction)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return math.huge
  end
  return vim.api.nvim_win_call(win, function()
    local line = direction > 0 and vim.api.nvim_buf_line_count(0) + 1 or 1
    return vim.fn.diff_filler(line)
  end)
end

-- Use the side that has real text at the edge we are moving towards. For an
-- added file that is the After side; for a deleted file it is the Before
-- side. Driving scrollbind from a filler-only edge makes Neovim remember an
-- offset past EOF and can leave almost the whole comparison blank.
local function diff_scroll_anchor(layout, direction, hovered_win)
  local best
  for _, win in ipairs({ layout.main_win, layout.after_win }) do
    if vim.api.nvim_win_is_valid(win) then
      local candidate = {
        win = win,
        filler = diff_edge_filler(win, direction),
        hovered = win == hovered_win and 1 or 0,
        lines = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win)),
      }
      if
        not best
        or candidate.filler < best.filler
        or (candidate.filler == best.filler and candidate.hovered > best.hovered)
        or (candidate.filler == best.filler and candidate.hovered == best.hovered and candidate.lines > best.lines)
      then
        best = candidate
      end
    end
  end
  return best and best.win
end

local function diff_scroll_capacity(win, direction)
  return vim.api.nvim_win_call(win, function()
    if direction > 0 then
      -- Stop as soon as EOF becomes visible. Native <C-E> and mouse-wheel
      -- scrolling allow the final line to reach the top of the window, which
      -- makes a long file appear to disappear into an empty viewport.
      return math.max(vim.api.nvim_buf_line_count(0) - vim.fn.line("w$"), 0)
    end
    return math.max(vim.fn.line("w0") - 1, 0)
  end)
end

local function diff_scroll_rhs(state, direction)
  local layout = state.preview_layout
  if
    not layout
    or not vim.api.nvim_win_is_valid(layout.main_win)
    or not vim.api.nvim_win_is_valid(layout.after_win)
  then
    return ""
  end

  local mouse = vim.fn.getmousepos()
  local anchor = diff_scroll_anchor(layout, direction, mouse.winid)
  if not anchor then
    return ""
  end
  local amount = tonumber(vim.o.mousescroll:match("ver:(%d+)")) or 3
  local steps = math.min(amount, diff_scroll_capacity(anchor, direction))
  if steps < 1 then
    return ""
  end

  local keys = (direction > 0 and "<C-E>" or "<C-Y>"):rep(steps)
  local current_win = vim.api.nvim_get_current_win()
  local mode = vim.api.nvim_get_mode().mode
  local leave_mode, restore_mode = "", ""
  if mode:sub(1, 1) == "i" then
    leave_mode, restore_mode = "<Esc>", "i"
  elseif mode:sub(1, 1) == "t" then
    leave_mode, restore_mode = "<C-\\><C-N>", "i"
  elseif mode == "v" or mode == "V" or mode == "\22" then
    leave_mode, restore_mode = "<Esc>", "gv"
  end

  if current_win == anchor then
    return leave_mode .. keys .. restore_mode
  end
  -- An expression mapping cannot change windows under textlock. Return real
  -- input commands instead: briefly make the anchor current so scrollbind is
  -- honoured, execute each screen-row scroll, then restore the user's focus.
  return leave_mode
    .. ("<Cmd>noautocmd call win_gotoid(%d)<CR>"):format(anchor)
    .. keys
    .. ("<Cmd>noautocmd call win_gotoid(%d)<CR>"):format(current_win)
    .. restore_mode
end

local function find_editor_window(state)
  local explorer = state.explorer
  local main_win = state.editor_win
  if not main_win or not vim.api.nvim_win_is_valid(main_win) or main_win == state.win then
    main_win = explorer and not explorer.closed and explorer.main or nil
  end
  if not main_win or not vim.api.nvim_win_is_valid(main_win) or main_win == state.win then
    for _, candidate in ipairs(vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(state.win))) do
      local candidate_buf = vim.api.nvim_win_get_buf(candidate)
      if candidate ~= state.win and vim.bo[candidate_buf].buftype == "" then
        main_win = candidate
        break
      end
    end
  end
  return main_win
end

-- Neovim preserves the shrunken height of winfixheight windows when the host
-- terminal grows again. Recalculate both fixed parts of the project layout
-- from the current UI size so repeated shrink/grow cycles cannot strand the
-- terminal or Git panel at one line.
function M.reflow_layout()
  if reflowing_layout or #vim.api.nvim_list_uis() == 0 then
    return
  end
  reflowing_layout = true
  local current_win = vim.api.nvim_get_current_win()

  local ok, err = pcall(function()
    local usable_rows = math.max(vim.o.lines - 2, 4)
    local min_terminal = vim.o.lines >= 24 and 6 or 2
    local min_upper = vim.o.lines >= 24 and 8 or math.max(3, math.floor(usable_rows * 0.55))

    for _, terminal in ipairs(Snacks.terminal.list()) do
      if
        terminal:win_valid()
        and terminal.opts
        and terminal.opts.position == "bottom"
        and terminal.opts.relative == "editor"
        and #vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(terminal.win)) > 1
      then
        -- Keep the height the terminal already has, so a reflow triggered by
        -- an unrelated panel never resets a terminal the user resized. Only
        -- pull it back inside the bounds that keep both windows usable.
        local current = vim.api.nvim_win_get_height(terminal.win)
        local terminal_height = math.max(min_terminal, math.min(current, math.max(1, usable_rows - min_upper)))
        if terminal_height ~= current then
          vim.wo[terminal.win].winfixheight = false
          pcall(vim.api.nvim_win_set_height, terminal.win, terminal_height)
          if vim.api.nvim_win_is_valid(terminal.win) then
            vim.wo[terminal.win].winfixheight = true
          end
        end
      end
    end

    for buf, state in pairs(states) do
      if not valid(state) then
        states[buf] = nil
      else
        local explorer_root = state.explorer and state.explorer.layout and state.explorer.layout.root
        if explorer_root and explorer_root:valid() then
          -- Depending on which async panel becomes ready first, the bottom
          -- terminal can span the full editor or only the right-hand editor
          -- column. The central editor height therefore is not a reliable
          -- measure of the left column. Divide the two real left windows
          -- directly so Project and Git are visually equal in either layout.
          local left_content_height = vim.api.nvim_win_get_height(explorer_root.win)
            + vim.api.nvim_win_get_height(state.win)
          local min_explorer = left_content_height >= 18 and 8 or left_content_height >= 10 and 5 or 2
          local max_git = math.max(1, left_content_height - min_explorer)
          local target = math.max(1, math.min(default_git_height(left_content_height), max_git))
          vim.wo[state.win].winfixheight = false
          pcall(vim.api.nvim_win_set_height, state.win, target)
          if vim.api.nvim_win_is_valid(state.win) then
            vim.wo[state.win].winfixheight = true
          end
          if state.explorer and state.explorer.layout and state.explorer.layout:valid() then
            state.explorer.layout:update()
          end
        end
      end
    end

    for _, explorer in ipairs(Snacks.picker.get({ source = "explorer" })) do
      local root = explorer.layout and explorer.layout.root
      if not explorer.closed and root and root:valid() then
        local preferred = explorer_preferred_widths[explorer]
        if preferred then
          local min_explorer_width = vim.o.columns >= 60 and 20 or 12
          local min_editor_width = vim.o.columns >= 80 and 30 or 10
          local max_explorer_width = math.max(1, vim.o.columns - min_editor_width - 1)
          local target = math.max(1, math.min(math.max(preferred, min_explorer_width), max_explorer_width))
          local fixed = vim.wo[root.win].winfixwidth
          vim.wo[root.win].winfixwidth = false
          pcall(vim.api.nvim_win_set_width, root.win, target)
          if root:valid() then
            vim.wo[root.win].winfixwidth = fixed
            explorer.layout:update()
          end
        end
      end
    end
  end)

  if current_win and vim.api.nvim_win_is_valid(current_win) then
    pcall(vim.api.nvim_set_current_win, current_win)
  end
  reflowing_layout = false
  if not ok then
    vim.schedule(function()
      Snacks.notify.error("Project layout resize failed: " .. tostring(err))
    end)
  end
end

local function queue_layout_reflow(delay)
  resize_generation = resize_generation + 1
  local generation = resize_generation
  vim.defer_fn(function()
    if generation == resize_generation then
      M.reflow_layout()
    end
  end, delay or 60)
end

TerminalTabs.setup({
  root = function()
    return LazyVim.root()
  end,
  on_layout_change = function()
    local activity = package.loaded["config.activity_bar"]
    if activity and activity.queue_reflow then
      activity.queue_reflow(80)
    else
      queue_layout_reflow(80)
    end
  end,
  on_layout_cancel = function()
    resize_generation = resize_generation + 1
  end,
})

activate_preview = function(state, preview, focus_preview)
  if not valid(state) or not valid_preview(preview) then
    return
  end

  local layout = state.preview_layout
  local layout_valid = layout
    and vim.api.nvim_win_is_valid(layout.main_win)
    and vim.api.nvim_win_is_valid(layout.after_win)
  if
    state.preview == preview
    and layout_valid
    and vim.api.nvim_win_get_buf(layout.main_win) == preview.bufs[1]
    and vim.api.nvim_win_get_buf(layout.after_win) == preview.bufs[2]
  then
    if focus_preview then
      vim.api.nvim_set_current_win(layout.after_win)
    end
    return
  end

  state.updating_preview = true
  if layout and not layout_valid then
    hide_preview(state, nil, true)
    state.updating_preview = true
    layout = nil
  end

  if layout then
    save_preview_views(state)
    for _, win in ipairs({ layout.main_win, layout.after_win }) do
      pcall(vim.api.nvim_win_call, win, function()
        vim.cmd("diffoff")
      end)
    end
  else
    local main_win = find_editor_window(state)
    if not main_win or not vim.api.nvim_win_is_valid(main_win) or main_win == state.win then
      state.updating_preview = false
      Snacks.notify.error("Git preview could not find the main editor window")
      return
    end

    local current_buf = vim.api.nvim_win_get_buf(main_win)
    local editor_context
    if preview_containing_buffer(state, current_buf) then
      editor_context = state.last_editor_context
      if not editor_context or not vim.api.nvim_buf_is_valid(editor_context.buf) then
        local alternate = vim.fn.bufnr("#")
        if
          alternate > 0
          and vim.api.nvim_buf_is_valid(alternate)
          and not preview_containing_buffer(state, alternate)
        then
          editor_context = capture_editor_context(main_win, alternate)
          editor_context.view = { lnum = 1, col = 0, topline = 1, leftcol = 0, skipcol = 0 }
        end
      end
    else
      editor_context = capture_editor_context(main_win, current_buf)
    end
    -- Dashboard and similar transient buffers use bufhidden=wipe. Replacing
    -- one with the Diff deletes it immediately, so retaining it as the editor
    -- context would leave the preview buffer as the last buffer in the main
    -- window. Deleting preview buffers during detach can then close the main
    -- editor window altogether. Use a durable blank buffer for restoration.
    if
      editor_context
      and vim.api.nvim_buf_is_valid(editor_context.buf)
      and vim.bo[editor_context.buf].bufhidden == "wipe"
    then
      editor_context = nil
    end
    if not editor_context or not vim.api.nvim_buf_is_valid(editor_context.buf) then
      local fallback = vim.api.nvim_create_buf(true, false)
      editor_context = capture_editor_context(main_win, fallback)
    end
    assert(editor_context, "Git preview editor context could not be captured")

    vim.api.nvim_win_set_buf(main_win, preview.bufs[1])
    local total_width = vim.api.nvim_win_get_width(main_win)
    local split_width = math.max(math.floor(total_width / 2), 10)
    split_width = math.min(split_width, math.max(total_width - 10, 1))
    local ok, after_win = pcall(vim.api.nvim_open_win, preview.bufs[2], false, {
      split = "right",
      win = main_win,
      width = split_width,
    })
    if not ok then
      vim.api.nvim_win_set_buf(main_win, editor_context.buf)
      restore_window_options(main_win, editor_context.options)
      pcall(vim.api.nvim_win_call, main_win, function()
        vim.fn.winrestview(editor_context.view)
      end)
      state.updating_preview = false
      Snacks.notify.error("Git preview could not create the right diff window")
      return
    end
    layout = {
      main_win = main_win,
      after_win = after_win,
      editor_context = editor_context,
    }
    state.preview_layout = layout
  end

  state.preview = preview
  state.editor_win = layout.main_win
  vim.w[layout.main_win].snacks_main = true
  vim.w[layout.after_win].snacks_main = true
  if state.explorer and not state.explorer.closed then
    state.explorer.main = layout.main_win
  end

  for _, item in ipairs({
    { win = layout.main_win, buf = preview.bufs[1], label = preview.before_label },
    { win = layout.after_win, buf = preview.bufs[2], label = preview.after_label },
  }) do
    vim.api.nvim_win_set_buf(item.win, item.buf)
    vim.api.nvim_win_call(item.win, function()
      vim.cmd("diffthis")
    end)
    vim.wo[item.win].foldenable = false
    vim.wo[item.win].wrap = false
    vim.wo[item.win].cursorline = true
    vim.wo[item.win].number = true
    vim.wo[item.win].relativenumber = false
    vim.wo[item.win].scrollbind = true
    vim.wo[item.win].cursorbind = false
    vim.wo[item.win].winbar = "  " .. item.label
  end

  local placement = preview.layout_placement
  if placement then
    local restored = PanelLayout.restore(placement.snapshot, { [placement.after_win] = layout.after_win })
    preview.layout_placement = nil
    if restored then
      resize_generation = resize_generation + 1
    end
  end

  pcall(vim.api.nvim_win_call, layout.after_win, function()
    vim.cmd("silent! diffupdate")
    vim.cmd("syncbind")
  end)
  -- winrestview() on one scroll-bound window also moves its partner. Restore
  -- both snapshots independently, then re-enable binding; otherwise the
  -- second restore overwrites the first and a tab round-trip changes position.
  vim.wo[layout.main_win].scrollbind = false
  vim.wo[layout.after_win].scrollbind = false
  for index, win in ipairs({ layout.main_win, layout.after_win }) do
    pcall(vim.api.nvim_win_call, win, function()
      vim.fn.winrestview(preview.views[index] or {
        lnum = 1,
        col = 0,
        topline = 1,
        leftcol = 0,
        skipcol = 0,
      })
    end)
  end
  vim.wo[layout.main_win].scrollbind = true
  vim.wo[layout.after_win].scrollbind = true
  if focus_preview then
    vim.api.nvim_set_current_win(layout.after_win)
  end

  state.updating_preview = false
end

-- ── hunks inside the diff ───────────────────────────────────────────────

local HUNK_ACTIONS = {
  stage = { glyph = "+", label = "Stage Hunk" },
  unstage = { glyph = "−", label = "Unstage Hunk" },
  discard = { glyph = "↺", label = "Discard Hunk" },
}

-- Which hunk operations a diff supports. Only an edit still in flight can be
-- moved: a commit's contents are history, and an untracked file has no earlier
-- version to throw a hunk back to.
local function hunk_actions(mode)
  if mode == "unstaged" then
    return { "discard", "stage" }
  elseif mode == "staged" then
    return { "unstage" }
  elseif mode == "untracked" then
    return { "stage" }
  end
  return {}
end

local function prepare_hunks(preview)
  preview.hunks = {}
  preview.hunk_marks = {}
  if #hunk_actions(preview.mode) == 0 then
    return
  end
  if GitOps.is_binary(preview.before) or GitOps.is_binary(preview.after) then
    return
  end
  preview.hunks = GitOps.hunks(preview.before, preview.after)
end

-- The buttons are virtual text at the end of the hunk's first line: the diff
-- buffers have to stay byte-identical to what git produced, so nothing may be
-- written into them. They are spaced out on purpose -- a click reports a screen
-- column, the column virtual text begins at can only be derived, and a cell of
-- slack between two buttons makes an off-by-one land on nothing instead of on
-- the wrong action.
local HUNK_BUTTON_GAP = 3

local function render_hunk_buttons(state, preview)
  local buf = preview.bufs and preview.bufs[2]
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, hunk_ns, 0, -1)
  preview.hunk_marks = {}
  local actions = hunk_actions(preview.mode)
  if #actions == 0 then
    return
  end
  local total = vim.api.nvim_buf_line_count(buf)
  for _, hunk in ipairs(preview.hunks or {}) do
    -- A hunk that only deletes has no line of its own on this side, so it
    -- belongs to the line it follows.
    local line = math.max(1, math.min(hunk.after_start, total))
    local strip, ranges = "", {}
    for index, name in ipairs(actions) do
      strip = strip .. string.rep(" ", index == 1 and 2 or HUNK_BUTTON_GAP)
      local at = vim.fn.strdisplaywidth(strip) + 1
      strip = strip .. HUNK_ACTIONS[name].glyph
      ranges[#ranges + 1] = { from = at - 1, to = at + 1, action = name, hunk = hunk }
    end
    vim.api.nvim_buf_set_extmark(buf, hunk_ns, line - 1, 0, {
      virt_text = { { strip, "Special" } },
      virt_text_pos = "eol",
      hl_mode = "combine",
    })
    preview.hunk_marks[line] = ranges
  end
end

-- Virtual text is not part of the line, so a click on it reports the buffer
-- line and a screen column and nothing more. The strip begins in the cell
-- after the line's last character, which is where the cursor would sit at the
-- end of the line.
local function hunk_button_at(state, preview, mouse)
  local layout = state.preview_layout
  local ranges = preview.hunk_marks and mouse and preview.hunk_marks[mouse.line]
  if not ranges or not layout or mouse.winid ~= layout.after_win then
    return
  end
  local text = vim.api.nvim_buf_get_lines(preview.bufs[2], mouse.line - 1, mouse.line, false)[1] or ""
  local position = vim.fn.screenpos(layout.after_win, mouse.line, #text + 1)
  if position.row == 0 or position.row ~= mouse.screenrow then
    return
  end
  for _, range in ipairs(ranges) do
    if mouse.screencol >= position.col + range.from - 1 and mouse.screencol <= position.col + range.to - 1 then
      return range
    end
  end
end

local function show_preview(state, entry, key, before, after, specs, focus_preview)
  if not valid(state) then
    return
  end

  local existing = state.previews[key]
  if valid_preview(existing) then
    activate_preview(state, existing, focus_preview)
    return
  elseif existing then
    delete_preview(state, existing)
  end

  state.preview_serial = state.preview_serial + 1
  local serial = state.preview_serial
  local source = entry.kind == "commit_file" and entry.short_hash or "CHANGES"
  local path_label = entry.path:gsub("/", "›"):gsub("[\r\n]", " ")
  local tab_label = ("Δ %s · %s"):format(path_label, source)
  local before_name = ("git-preview://%d/%d/before/%s"):format(state.buf, serial, path_label)
  local after_name = ("git-diff://%d/%d/%s"):format(state.buf, serial, tab_label)
  local before_buf = preview_buffer(false, before_name, entry.old_path or entry.path, before)
  local after_buf = preview_buffer(true, after_name, entry.path, after)
  local preview = {
    key = key,
    entry = entry,
    bufs = { before_buf, after_buf },
    views = {},
    mode = specs.mode,
    before = before,
    after = after,
    before_label = specs.before_label,
    after_label = specs.after_label,
  }
  state.previews[key] = preview
  prepare_hunks(preview)
  render_hunk_buttons(state, preview)

  for _, buf in ipairs(preview.bufs) do
    vim.keymap.set("n", "<ScrollWheelDown>", function()
      return diff_scroll_rhs(state, 1)
    end, {
      buffer = buf,
      expr = true,
      replace_keycodes = true,
      silent = true,
      desc = "Scroll both Git diff windows down",
    })
    vim.keymap.set("n", "<ScrollWheelUp>", function()
      return diff_scroll_rhs(state, -1)
    end, {
      buffer = buf,
      expr = true,
      replace_keycodes = true,
      silent = true,
      desc = "Scroll both Git diff windows up",
    })
    for _, item in ipairs({
      { key = "a", action = "stage", desc = "Stage the hunk under the cursor" },
      { key = "u", action = "unstage", desc = "Unstage the hunk under the cursor" },
      { key = "x", action = "discard", desc = "Discard the hunk under the cursor" },
    }) do
      vim.keymap.set("n", item.key, function()
        M._hunk_action_at_cursor(item.action)
      end, { buffer = buf, silent = true, desc = item.desc })
    end
  end
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    once = true,
    buffer = after_buf,
    callback = function()
      if not preview.deleting then
        vim.schedule(function()
          delete_preview(state, preview)
        end)
      end
    end,
  })

  activate_preview(state, preview, focus_preview)
end

local function read_worktree(root, path, callback)
  run({ "cat", "--", vim.fs.joinpath(root, path) }, callback, false)
end

local function read_blob(root, spec, callback)
  if not spec then
    vim.schedule(function()
      callback("", 0)
    end)
    return
  end
  run_git(root, { "show", spec }, callback, false)
end

-- What a row's diff compares, and what that makes it: an edit still in flight
-- (which can be staged, unstaged or thrown away) or a piece of history.
local function preview_specs(entry)
  local status = entry.status
  if entry.kind == "commit_file" then
    local code = status:sub(1, 1)
    return {
      mode = "commit",
      before_spec = code ~= "A" and (entry.commit .. "^1:" .. (entry.old_path or entry.path)) or nil,
      after_spec = code ~= "D" and (entry.commit .. ":" .. entry.path) or nil,
      before_label = "Before · " .. entry.short_hash .. "^",
      after_label = "After · " .. entry.short_hash,
    }
  end
  local index_status, worktree_status = status:sub(1, 1), status:sub(2, 2)
  if status == "??" then
    return {
      mode = "untracked",
      after_worktree = entry.path,
      before_label = "Before · empty",
      after_label = "After · worktree",
    }
  end
  -- Which of the two versions the row is about. A row knows from its group; an
  -- entry built without one is read off the status, the way every row was
  -- before the panel had groups.
  local indexed = entry.group == "staged" or (not entry.group and worktree_status == " ")
  if not indexed then
    return {
      mode = "unstaged",
      -- Against the index entry for the path as it is named now: a rename is
      -- already recorded there under the new name, and the old one is gone.
      before_spec = ":" .. entry.path,
      after_worktree = worktree_status ~= "D" and entry.path or nil,
      before_label = "Before · index",
      after_label = "After · worktree",
    }
  end
  return {
    mode = "staged",
    before_spec = index_status ~= "A" and ("HEAD:" .. (entry.old_path or entry.path)) or nil,
    after_spec = index_status ~= "D" and (":" .. entry.path) or nil,
    before_label = "Before · HEAD",
    after_label = "After · index",
  }
end

-- Both sides of a diff, read together. A side that is simply absent is not an
-- error -- a file that was added has no previous version -- but a side git
-- refuses to produce is, and the caller is told which one.
local function read_sides(root, path, specs, callback)
  local before, after, failure
  local before_done, after_done = false, false
  local function finish()
    if before_done and after_done then
      callback(before, after, failure)
    end
  end
  local function receive(side)
    return function(output, code, stderr)
      if code ~= 0 and not failure then
        local detail = vim.trim(stderr or "")
        failure = ("Git could not read `%s` (%s, exit %s)%s"):format(
          path,
          side,
          code,
          detail ~= "" and ": " .. detail or ""
        )
      end
      if side == "before" then
        before, before_done = output, true
      else
        after, after_done = output, true
      end
      finish()
    end
  end
  if specs.before_worktree then
    read_worktree(root, specs.before_worktree, receive("before"))
  else
    read_blob(root, specs.before_spec, receive("before"))
  end
  if specs.after_worktree then
    read_worktree(root, specs.after_worktree, receive("after"))
  else
    read_blob(root, specs.after_spec, receive("after"))
  end
end

local function open_file_preview(state, entry, focus_preview)
  local key = entry_key(entry)
  local existing = state.previews[key]
  if valid_preview(existing) then
    if state.preview_request_key then
      state.preview_generation = state.preview_generation + 1
      state.preview_request_key = nil
      state.preview_request_focus = nil
    end
    activate_preview(state, existing, focus_preview)
    return
  elseif existing then
    delete_preview(state, existing)
  end
  if state.preview_request_key == key then
    state.preview_request_focus = state.preview_request_focus or focus_preview
    return
  end

  state.preview_generation = state.preview_generation + 1
  local generation = state.preview_generation
  state.preview_request_key = key
  state.preview_request_focus = focus_preview
  local specs = preview_specs(entry)

  read_sides(state.root, entry.path, specs, function(before, after, err)
    if not valid(state) or state.preview_generation ~= generation then
      return
    end
    local should_focus = state.preview_request_focus
    state.preview_request_key = nil
    state.preview_request_focus = nil
    if err then
      Snacks.notify.error(err)
      return
    end
    show_preview(state, entry, key, before or "", after or "", specs, should_focus)
  end)
end

-- Bring an open diff back in step with the repository. Both sides are read
-- again and written only where they differ: the reader may be scrolled into
-- the middle of the file, and replacing lines that did not change would throw
-- that away for nothing.
function reload_preview(state, preview, entry)
  local specs = preview_specs(entry)
  preview.reload_serial = (preview.reload_serial or 0) + 1
  local serial = preview.reload_serial
  read_sides(state.root, entry.path, specs, function(before, after, err)
    if not valid(state) or not valid_preview(preview) or preview.reload_serial ~= serial then
      return
    end
    if err then
      return notify_error(err)
    end
    before, after = before or "", after or ""
    local changed = preview.before ~= before or preview.after ~= after or preview.mode ~= specs.mode
    preview.entry = entry
    preview.mode = specs.mode
    preview.before, preview.after = before, after
    preview.before_label, preview.after_label = specs.before_label, specs.after_label
    if not changed then
      return
    end
    set_preview_content(preview.bufs[1], entry.old_path or entry.path, before)
    set_preview_content(preview.bufs[2], entry.path, after)
    prepare_hunks(preview)
    render_hunk_buttons(state, preview)
    local layout = state.preview_layout
    if not layout or state.preview ~= preview then
      return
    end
    for _, item in ipairs({
      { win = layout.main_win, label = preview.before_label },
      { win = layout.after_win, label = preview.after_label },
    }) do
      if vim.api.nvim_win_is_valid(item.win) then
        vim.wo[item.win].winbar = "  " .. item.label
        pcall(vim.api.nvim_win_call, item.win, function()
          vim.cmd("diffupdate")
        end)
      end
    end
  end)
end

local function load_commit_files(state, commit)
  local hash = commit.full_hash
  local cached = state.commit_files[hash]
  if cached and not cached.error then
    render(state)
    return
  end
  state.commit_files[hash] = { loading = true, files = {} }
  render(state)

  run_git(state.root, {
    "-c",
    "core.quotepath=false",
    "diff-tree",
    "--root",
    "--first-parent",
    "--no-commit-id",
    "--name-status",
    "-z",
    "-r",
    "-M",
    hash,
  }, function(output, code)
    if not valid(state) then
      return
    end
    local files = {}
    local records = vim.split(output, "\0", { plain = true, trimempty = true })
    local index = 1
    while index <= #records do
      local status = records[index] or ""
      index = index + 1
      local rename = status:sub(1, 1):find("[RC]") ~= nil
      local old_path = rename and records[index] or nil
      local path = rename and records[index + 1] or records[index]
      index = index + (rename and 2 or 1)
      if path then
        files[#files + 1] = {
          kind = "commit_file",
          status = status,
          path = path,
          old_path = old_path,
          commit = hash,
          short_hash = commit.hash,
        }
      end
    end
    state.commit_files[hash] = { loading = false, files = files, error = code ~= 0 }
    if state.expanded[hash] then
      if code ~= 0 then
        Snacks.notify.error(("Git could not read changed files for `%s`"):format(commit.hash))
      end
      render(state)
    end
  end, false)
end

local function action(state, focus_preview)
  local entry = state.entries[vim.api.nvim_win_get_cursor(state.win)[1]]
  if not entry then
    return
  end
  if entry.kind == "section" then
    state.collapsed[entry.section] = not state.collapsed[entry.section]
    render(state)
  elseif entry.kind == "commit_load_more" then
    if not entry.loading then
      load_commits(state)
    end
  elseif entry.kind == "timeline_load_more" then
    if not entry.loading then
      load_timeline(state)
    end
  elseif entry.kind == "commit" then
    if state.expanded[entry.full_hash] then
      state.expanded[entry.full_hash] = nil
      render(state)
    else
      state.expanded[entry.full_hash] = true
      load_commit_files(state, entry)
    end
  else
    open_file_preview(state, entry, focus_preview)
  end
end

local global_mouse_mappings_set = false

local function mouse_in_panel_content(state, mouse)
  -- A statusline/separator click reports line 0. Let Neovim handle that event
  -- so the user can still drag the split border to resize the panel.
  return valid(state) and mouse and mouse.winid == state.win and mouse.line >= 1
end

local function mouse_hits_panel_line(state, mouse)
  if not mouse_in_panel_content(state, mouse) then
    return false
  end
  if mouse.line > vim.api.nvim_buf_line_count(state.buf) then
    return false
  end

  -- getmousepos() can report the final buffer line when the pointer is on a
  -- screen row below EOF. Compare the line's real screen position as well so
  -- panel padding never acts on the final commit.
  local position = vim.fn.screenpos(state.win, mouse.line, 1)
  return position.row > 0 and mouse.screenrow == position.row
end

-- `focus = false` means "only finish a move the editor already made": the
-- terminal has to still be the current window on the next tick. Rebuilding a
-- panel layout moves windows around, and every such move fires WinEnter on the
-- terminal; forcing focus from there stole the cursor out of the sidebar (and
-- out of the editor at startup) after each Activity Bar action.
local function queue_terminal_insert(win, opts)
  if not win or win < 1 or not vim.api.nvim_win_is_valid(win) then
    return
  end
  local buf = vim.api.nvim_win_get_buf(win)
  if vim.bo[buf].buftype ~= "terminal" or vim.bo[buf].filetype ~= "snacks_terminal" then
    return
  end
  local focus = not (opts and opts.focus == false)
  vim.schedule(function()
    if not vim.api.nvim_win_is_valid(win) or not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    if vim.api.nvim_win_get_buf(win) ~= buf then
      return
    end
    if not focus and vim.api.nvim_get_current_win() ~= win then
      return
    end
    vim.api.nvim_set_current_win(win)
    vim.cmd.startinsert()
  end)
end

-- These mappings are global and are never removed, so once a Git panel has
-- been opened they permanently shadow the Activity Bar's own drag handling --
-- including for the Explorer and Search panels, which this module knows
-- nothing about. Hand anything not ours back to the Activity Bar's rule
-- before letting it through, or dragging inside those panels starts selecting
-- their text again.
local function swallow_outside_panel(mouse, key)
  local activity = package.loaded["config.activity_bar"]
  if activity and activity._over_panel and activity._over_panel(mouse) then
    return ""
  end
  local scrollbar = package.loaded["config.picker_scrollbar"]
  if scrollbar and scrollbar._over_terminal and scrollbar._over_terminal(mouse) then
    return ""
  end
  return key
end

local function mouse_panel_target()
  local mouse = vim.fn.getmousepos()
  for buf, state in pairs(states) do
    if not valid(state) then
      states[buf] = nil
    elseif mouse_in_panel_content(state, mouse) then
      return state, mouse
    end
  end
  return nil, mouse
end

local function mouse_preview_target()
  local mouse = vim.fn.getmousepos()
  for buf, state in pairs(states) do
    if not valid(state) then
      states[buf] = nil
    else
      local layout = state.preview_layout
      if layout and (mouse.winid == layout.main_win or mouse.winid == layout.after_win) then
        return state
      end
    end
  end
end

local function position_panel_mouse(state, mouse)
  if not mouse_in_panel_content(state, mouse) then
    return false
  end
  local mode = vim.api.nvim_get_mode().mode
  if mode == "v" or mode == "V" or mode == "\22" then
    vim.cmd("normal! \027")
  elseif mode:sub(1, 1) == "i" or mode:sub(1, 1) == "t" then
    vim.cmd("stopinsert")
  end
  vim.api.nvim_set_current_win(state.win)
  if not mouse_hits_panel_line(state, mouse) then
    return false
  end
  vim.api.nvim_win_set_cursor(state.win, { mouse.line, 0 })
  return true
end

-- ── acting on a change ──────────────────────────────────────────────────

-- The paths to hand git. A rename is two entries in the index, so taking one
-- back out has to name both or the old path stays deleted there.
local function action_paths(action, changes)
  local paths = {}
  for _, change in ipairs(changes) do
    paths[#paths + 1] = change.path
    if action == "unstage" and change.old_path then
      paths[#paths + 1] = change.old_path
    end
  end
  return paths
end

-- What a row's action applies to. A section header covers the rows of its own
-- group, and of those only the ones the action is actually possible for:
-- handing git a path it cannot stage or unstage turns the whole batch into an
-- error.
local function changes_for(state, entry, scope, action)
  if scope ~= "all" then
    return { entry }
  end
  local changes = {}
  for _, change in ipairs(changes_in(state, entry.section)) do
    if GitOps.file_actions(change.status, change.group)[action] then
      changes[#changes + 1] = change
    end
  end
  return changes
end

local function run_change_action(state, action, changes)
  local buf = state.buf
  local function finished(err)
    if err then
      notify_error(err)
    end
    -- Restoring a file touches only the working tree, and the panel's watcher
    -- only ever sees `.git`, so nothing else would bring the list back in step.
    M.refresh(buf, { status_only = true })
  end
  if action == "stage" then
    GitOps.stage(state.root, action_paths(action, changes), finished)
  elseif action == "unstage" then
    GitOps.unstage(state.root, action_paths(action, changes), finished)
  elseif action == "discard" then
    GitOps.discard(state.root, changes, finished)
  end
end

local function cursor_mouse(state)
  local line = vim.api.nvim_win_get_cursor(state.win)[1]
  local position = vim.fn.screenpos(state.win, line, 1)
  return {
    screenrow = position.row > 0 and position.row or 1,
    screencol = position.col > 0 and position.col or 1,
  }
end

local function confirm(state, prompt, label, mouse, proceed)
  ContextMenu.open({
    { label = prompt, enabled = false },
    { separator = true },
    { label = label, action = proceed },
    { label = "Cancel", action = function() end },
  }, mouse or cursor_mouse(state), {
    filetype = "git_panel_confirm",
    min_width = math.min(vim.api.nvim_strwidth(prompt) + 4, math.max(vim.o.columns - 4, 20)),
  })
end

-- Discarding is the one action here that destroys work no git command can
-- bring back, so it asks first -- and says what exactly will be lost, because
-- "discard 12 files" and "delete a file git has never seen" are not the same
-- warning.
local function confirm_discard(state, changes, mouse, proceed)
  local deletions = 0
  for _, change in ipairs(changes) do
    if change.status == "??" then
      deletions = deletions + 1
    end
  end
  local subject = #changes == 1 and ("`%s`"):format(changes[1].path) or ("%d files"):format(#changes)
  local prompt = ("Discard changes in %s?"):format(subject)
  if deletions > 0 then
    prompt = ("Discard %s? %d untracked file(s) will be deleted."):format(subject, deletions)
  end
  confirm(state, prompt, "Discard Changes", mouse, proceed)
end

local function activate_action(state, action, entry, scope, mouse)
  local changes = changes_for(state, entry, scope, action)
  if #changes == 0 then
    return
  end
  if action ~= "discard" then
    return run_change_action(state, action, changes)
  end
  confirm_discard(state, changes, mouse, function()
    run_change_action(state, action, changes)
  end)
end

local function button_at(state, mouse)
  local ranges = state.buttons and mouse and state.buttons[mouse.line]
  if not ranges or not mouse_hits_panel_line(state, mouse) then
    return
  end
  for _, range in ipairs(ranges) do
    if mouse.column >= range.from and mouse.column <= range.to then
      return range
    end
  end
end

-- A click inside the panel: the button it landed on, or the row's own action.
-- Only one of the two ever runs, or staging a file would also open its diff.
local function activate_click(state, mouse)
  local range = button_at(state, mouse)
  if not range then
    return action(state, false)
  end
  activate_action(state, range.action, range.entry, range.scope, mouse)
end

-- ── acting on a hunk ────────────────────────────────────────────────────

local function preview_at_window(win)
  for buf, state in pairs(states) do
    if not valid(state) then
      states[buf] = nil
    else
      local layout = state.preview_layout
      local shown = layout and win and (win == layout.main_win or win == layout.after_win)
      if shown and valid_preview(state.preview) then
        return state, state.preview, win == layout.after_win and "after" or "before"
      end
    end
  end
end

local function run_hunk_action(state, preview, name, hunk)
  local entry = preview.entry
  -- The diff the reader is looking at is what the hunk's line numbers mean, so
  -- it is what git_ops checks the repository against before writing anything.
  local expected = { before = preview.before, after = preview.after }
  local buf = state.buf
  local function finished(err)
    if err then
      notify_error(err)
    end
    M.refresh(buf, { status_only = true })
  end
  if name == "stage" then
    GitOps.stage_hunk(state.root, entry.path, hunk, expected, finished)
  elseif name == "unstage" then
    GitOps.unstage_hunk(state.root, entry.path, hunk, expected, finished)
  elseif name == "discard" then
    GitOps.discard_hunk(state.root, entry.path, hunk, expected, finished)
  end
end

local function activate_hunk_action(state, preview, name, hunk, mouse)
  if not hunk or not vim.tbl_contains(hunk_actions(preview.mode), name) then
    return
  end
  if name ~= "discard" then
    return run_hunk_action(state, preview, name, hunk)
  end
  local prompt = ("Discard this hunk of `%s`?"):format(preview.entry.path)
  confirm(state, prompt, "Discard Hunk", mouse, function()
    run_hunk_action(state, preview, name, hunk)
  end)
end

-- Split in two on purpose: the hit test is all an <expr> mapping may do under
-- textlock, and acting on the result has to wait for the event to finish.
local function preview_button_hit(mouse)
  local state, preview, side = preview_at_window(mouse and mouse.winid)
  if not state or side ~= "after" then
    return
  end
  local range = hunk_button_at(state, preview, mouse)
  if range then
    return range, state, preview
  end
end

function M._handle_preview_click(mouse)
  local range, state, preview = preview_button_hit(mouse)
  if not range then
    return false
  end
  activate_hunk_action(state, preview, range.action, range.hunk, mouse)
  return true
end

-- The same three actions from the keyboard, on the hunk under the cursor.
function M._hunk_action_at_cursor(name)
  local win = vim.api.nvim_get_current_win()
  local state, preview, side = preview_at_window(win)
  if not state then
    return
  end
  local line = vim.api.nvim_win_get_cursor(win)[1]
  activate_hunk_action(state, preview, name, GitOps.hunk_at(preview.hunks or {}, side, line))
end

-- ── the hovered row ─────────────────────────────────────────────────────

local function panel_at_window(win)
  for buf, state in pairs(states) do
    if not valid(state) then
      states[buf] = nil
    elseif win and state.win == win then
      return state
    end
  end
end

local function set_hover(state, line, column)
  state.hover_line, state.hover_column = line, column
  follow_active_row(state)
  -- Which button is lit changes with the column alone, without the row moving.
  if line and state.active_line == line then
    render_row(state, line)
  end
end

function M._handle_mouse_move(mouse)
  local target = panel_at_window(mouse and mouse.winid)
  for buf, state in pairs(states) do
    if not valid(state) then
      states[buf] = nil
    elseif state ~= target and state.hover_line then
      set_hover(state, nil, nil)
    end
  end
  if not target then
    return false
  end
  local line = mouse_hits_panel_line(target, mouse) and mouse.line or nil
  local column = line and mouse.column or nil
  if target.hover_line == line and target.hover_column == column then
    return false
  end
  set_hover(target, line, column)
  return true
end

-- 'mousemoveevent' is global and makes the terminal report every pointer
-- movement, so it is switched on only while a panel is on screen and put back
-- exactly as it was once the last one is gone.
local hover_events_original

local function sync_hover_events()
  local wanted = false
  for buf, state in pairs(states) do
    if valid(state) then
      wanted = true
    else
      states[buf] = nil
    end
  end
  if wanted and hover_events_original == nil then
    hover_events_original = vim.o.mousemoveevent
    vim.o.mousemoveevent = true
  elseif not wanted and hover_events_original ~= nil then
    vim.o.mousemoveevent = hover_events_original
    hover_events_original = nil
  end
end

local function workspace_path(state, entry)
  if not (state and state.root and entry and entry.path) then
    return
  end
  return vim.fs.normalize(vim.fs.joinpath(state.root, entry.path))
end

local function workspace_file_exists(path)
  local stat = path and vim.uv.fs_stat(path) or nil
  return stat ~= nil and stat.type == "file"
end

local function notify_missing_workspace_file(entry)
  local message = ("Workspace file does not exist: `%s`"):format(entry.path)
  if rawget(_G, "Snacks") and Snacks.notify then
    Snacks.notify.warn(message)
  else
    vim.notify(message, vim.log.levels.WARN)
  end
end

local function open_workspace_file(state, entry)
  local path = workspace_path(state, entry)
  if not workspace_file_exists(path) then
    notify_missing_workspace_file(entry)
    return false
  end

  local buf = vim.fn.bufadd(path)
  local loaded, load_error = pcall(vim.fn.bufload, buf)
  if not loaded then
    local message = ("Failed to open workspace file `%s`: %s"):format(entry.path, tostring(load_error))
    if rawget(_G, "Snacks") and Snacks.notify then
      Snacks.notify.error(message)
    else
      vim.notify(message, vim.log.levels.ERROR)
    end
    return false
  end
  -- Recheck after loading so a file removed between the menu click and buffer
  -- creation never turns into an empty, misleading editor buffer.
  if not workspace_file_exists(path) then
    notify_missing_workspace_file(entry)
    return false
  end

  M.open_buffer(buf)
  return true
end

-- The right-click menu names the same actions the row's buttons offer, plus
-- the two ways to open what the row points at. Everything a row cannot do is
-- listed and greyed rather than hidden, so the menu does not change shape
-- between one file and the next.
local function action_spec(name)
  for _, spec in ipairs(ROW_ACTIONS) do
    if spec.action == name then
      return spec
    end
  end
end

-- The diff's own menu: what can be done to the hunk that was clicked, then
-- the same three actions for the whole file the diff belongs to.
local function preview_context_entries(state, preview, side, mouse)
  local entries = {}
  local available = hunk_actions(preview.mode)
  local hunk = GitOps.hunk_at(preview.hunks or {}, side, mouse.line)
  for _, name in ipairs({ "stage", "unstage", "discard" }) do
    if vim.tbl_contains(available, name) then
      entries[#entries + 1] = {
        label = HUNK_ACTIONS[name].label,
        enabled = hunk ~= nil,
        action = function()
          activate_hunk_action(state, preview, name, hunk, mouse)
        end,
      }
    end
  end

  local entry = preview.entry
  if entry.kind == "worktree_file" then
    local allowed = GitOps.file_actions(entry.status, entry.group)
    if #entries > 0 then
      entries[#entries + 1] = { separator = true }
    end
    for _, name in ipairs({ "stage", "unstage", "discard" }) do
      entries[#entries + 1] = {
        label = action_spec(name).label,
        enabled = allowed[name] == true,
        action = function()
          activate_action(state, name, entry, "file", mouse)
        end,
      }
    end
  end
  return entries
end

local function workspace_context_entries(state, entry, mouse)
  local entries = {}
  if entry.kind ~= "section" then
    if entry.kind == "worktree_file" then
      entries[#entries + 1] = {
        label = "Open Changes",
        action = function()
          open_file_preview(state, entry, true)
        end,
      }
    end
    entries[#entries + 1] = {
      label = "Open File",
      enabled = workspace_file_exists(workspace_path(state, entry)),
      action = function()
        open_workspace_file(state, entry)
      end,
    }
  end

  local allowed, scope = entry_actions(state, entry)
  if allowed then
    if #entries > 0 then
      entries[#entries + 1] = { separator = true }
    end
    for _, name in ipairs({ "stage", "unstage", "discard" }) do
      -- A section never offers to discard, so it does not list it either.
      if not (scope == "all" and name == "discard") then
        local spec = action_spec(name)
        entries[#entries + 1] = {
          label = scope == "all" and spec.all or spec.label,
          enabled = allowed[name] == true,
          action = function()
            activate_action(state, name, entry, scope, mouse)
          end,
        }
      end
    end
  end
  return entries
end

local function set_all_collapsed(state, collapsed)
  for _, section in ipairs({ "changes", "commits", "timeline" }) do
    state.collapsed[section] = collapsed
  end
  render(state)
end

-- Rows with no actions of their own -- a commit, a heading, the empty space
-- below the list -- still answer a right click, with what can be done to the
-- panel itself. A right click that does nothing reads as broken, and Neovim's
-- built-in PopUp menu is not an acceptable stand-in for it.
local function panel_context_entries(state, mouse)
  local entries = {}
  local row = mouse_hits_panel_line(state, mouse) and state.entries[mouse.line] or nil
  if row and row.kind == "commit" then
    entries[#entries + 1] = {
      label = "Copy Commit Hash",
      action = function()
        vim.fn.setreg('"', row.full_hash)
        pcall(vim.fn.setreg, "+", row.full_hash)
      end,
    }
    entries[#entries + 1] = { separator = true }
  end

  local allowed = change_actions(state.changes)
  entries[#entries + 1] = {
    label = "Stage All Changes",
    enabled = allowed.stage,
    action = function()
      activate_action(state, "stage", nil, "all", mouse)
    end,
  }
  entries[#entries + 1] = {
    label = "Unstage All Changes",
    enabled = allowed.unstage,
    action = function()
      activate_action(state, "unstage", nil, "all", mouse)
    end,
  }
  entries[#entries + 1] = { separator = true }
  entries[#entries + 1] = {
    label = "Collapse All Sections",
    action = function()
      set_all_collapsed(state, true)
    end,
  }
  entries[#entries + 1] = {
    label = "Expand All Sections",
    action = function()
      set_all_collapsed(state, false)
    end,
  }
  entries[#entries + 1] = { separator = true }
  entries[#entries + 1] = {
    label = "Refresh",
    action = function()
      M.refresh(state.buf)
    end,
  }
  return entries
end

local function context_entry_at_mouse(state, mouse)
  if not mouse_hits_panel_line(state, mouse) then
    return
  end
  local entry = state.entries[mouse.line]
  if entry and (entry.kind == "worktree_file" or entry.kind == "commit_file") then
    return entry
  end
  if entry and entry.kind == "section" and entry_actions(state, entry) then
    return entry
  end
end

local context_menu_registered = false

local function setup_context_menu()
  if context_menu_registered then
    return
  end
  context_menu_registered = true
  ContextMenu.setup()
  ContextMenu.register("git_panel", function(mouse)
    for buf, state in pairs(states) do
      if not valid(state) then
        states[buf] = nil
      elseif mouse_in_panel_content(state, mouse) then
        local entry = context_entry_at_mouse(state, mouse)
        vim.schedule(function()
          if not valid(state) then
            return
          end
          -- Below the last line there is no row to put the cursor on, which is
          -- not a reason to withhold the panel's own menu.
          position_panel_mouse(state, mouse)
          local entries = entry and workspace_context_entries(state, entry, mouse)
            or panel_context_entries(state, mouse)
          ContextMenu.open(entries, mouse, { filetype = "git_panel_context_menu" })
        end)
        return true
      end
    end
  end)

  ContextMenu.register("git_diff", function(mouse)
    local state, preview, side = preview_at_window(mouse and mouse.winid)
    if not state or (mouse.line or 0) < 1 then
      return
    end
    local entries = preview_context_entries(state, preview, side, mouse)
    if #entries == 0 then
      return
    end
    vim.schedule(function()
      if not valid(state) or not valid_preview(preview) then
        return
      end
      if vim.api.nvim_win_is_valid(mouse.winid) then
        vim.api.nvim_set_current_win(mouse.winid)
        pcall(vim.api.nvim_win_set_cursor, mouse.winid, { mouse.line, 0 })
      end
      ContextMenu.open(entries, mouse, { filetype = "git_diff_context_menu" })
    end)
    return true
  end)
end

-- Buffer-local mappings are only resolved from the window that owned focus
-- before a click. This dispatcher lets the very first click on the Git panel
-- work even when focus was in the editor, Explorer, or terminal.
local function setup_global_mouse_mappings()
  if global_mouse_mappings_set then
    return
  end
  global_mouse_mappings_set = true

  for _, lhs in ipairs({ "<LeftMouse>", "<2-LeftMouse>", "<3-LeftMouse>", "<4-LeftMouse>" }) do
    local key = lhs
    vim.keymap.set({ "n", "x", "i" }, key, function()
      local state, mouse = mouse_panel_target()
      -- A press outside an open menu dismisses it and does nothing else. This
      -- has to come first: everything below swallows presses over a panel, and
      -- a swallowed press would leave the menu on screen.
      if ContextMenu.dismiss(mouse) then
        return ""
      end
      if state then
        vim.schedule(function()
          if position_panel_mouse(state, mouse) then
            activate_click(state, mouse)
          end
        end)
        return ""
      end
      if key == "<LeftMouse>" and preview_button_hit(mouse) then
        vim.schedule(function()
          M._handle_preview_click(mouse)
        end)
        return ""
      end
      local activity = package.loaded["config.activity_bar"]
      if activity and activity._handle_mouse and activity._handle_mouse(mouse) then
        return ""
      end
      local scrollbar = package.loaded["config.picker_scrollbar"]
      if scrollbar and scrollbar.handle_mouse and scrollbar.handle_mouse(mouse) then
        return ""
      end
      if activity and activity._handle_list_click and activity._handle_list_click(mouse) then
        return ""
      end
      -- Multi-clicks select a word or a line; inside a panel or over the
      -- terminal that is meaningless and strands them in Visual mode.
      if key ~= "<LeftMouse>" then
        if activity and activity._over_panel and activity._over_panel(mouse) then
          return ""
        end
        if scrollbar and scrollbar._over_terminal and scrollbar._over_terminal(mouse) then
          return ""
        end
      end
      queue_terminal_insert(mouse and mouse.winid)
      return key
    end, { expr = true, silent = true, desc = "Toggle or open Git panel item" })
  end
  -- VSCode reveals a row's actions when the pointer is over it. In a terminal
  -- that needs 'mousemoveevent', which the panel switches on for as long as it
  -- is on screen. Never swallow the key: other hover features want it too.
  vim.keymap.set({ "n", "x", "i", "t" }, "<MouseMove>", function()
    -- An <expr> mapping runs under textlock, where redrawing a row is illegal.
    local mouse = vim.fn.getmousepos()
    vim.schedule(function()
      M._handle_mouse_move(mouse)
    end)
    return "<MouseMove>"
  end, { expr = true, silent = true, desc = "Track the Git panel's hovered row" })

  vim.keymap.set({ "n", "x", "i" }, "<LeftDrag>", function()
    local state, mouse = mouse_panel_target()
    if state then
      vim.schedule(function()
        position_panel_mouse(state, mouse)
      end)
      return ""
    end
    local scrollbar = package.loaded["config.picker_scrollbar"]
    if scrollbar and scrollbar.handle_drag and scrollbar.handle_drag(mouse) then
      return ""
    end
    return swallow_outside_panel(mouse, "<LeftDrag>")
  end, { expr = true, silent = true, desc = "Position Git panel cursor" })
  vim.keymap.set({ "n", "x", "i" }, "<LeftRelease>", function()
    local scrollbar = package.loaded["config.picker_scrollbar"]
    if scrollbar and scrollbar.handle_release and scrollbar.handle_release() then
      return ""
    end
    local state, mouse = mouse_panel_target()
    if state then
      return ""
    end
    return swallow_outside_panel(mouse, "<LeftRelease>")
  end, { expr = true, silent = true, desc = "Finish Git panel click" })

  -- This is also the synchronisation path when the mouse is over a diff that
  -- does not own focus. Do not add a WinScrolled callback that enters the
  -- source window with nvim_win_call(): Snacks can then re-evaluate its main
  -- window and tear down the diff layout while a wheel event is still being
  -- processed. diff_scroll_rhs() uses noautocmd window changes instead.
  for lhs, direction in pairs({
    ["<ScrollWheelDown>"] = 1,
    ["<ScrollWheelUp>"] = -1,
  }) do
    local key = lhs
    local scroll_direction = direction
    vim.keymap.set({ "n", "x", "i", "t" }, key, function()
      local state = mouse_preview_target()
      if state then
        return diff_scroll_rhs(state, scroll_direction)
      end
      return key
    end, {
      expr = true,
      replace_keycodes = true,
      silent = true,
      desc = "Scroll both Git diff windows",
    })
  end
end

function M.close()
  local state = current_state()
  if not state then
    return
  end
  close_preview(state)
  local tab = vim.api.nvim_win_get_tabpage(state.win)
  git_panel_placements[placement_key(state.root, tab)] = {
    snapshot = PanelLayout.capture(state.win),
    panel_win = state.win,
  }
  if vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
end

-- Activity Bar owns the sidebar window lifecycle. Detach the Git model from
-- that window without recording a standalone Git-panel placement, then leave
-- a scratch buffer behind so the controller can replace the slot atomically.
function M.detach(state)
  state = state or current_state()
  if not valid(state) then
    return
  end
  close_preview(state)
  local win, buf = state.win, state.buf
  states[buf] = nil
  sync_hover_events()
  if vim.api.nvim_win_is_valid(win) then
    local scratch = vim.api.nvim_create_buf(false, true)
    vim.bo[scratch].bufhidden = "wipe"
    vim.api.nvim_win_set_buf(win, scratch)
  end
  if vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
  return win
end

function M.close_explorer()
  for _, explorer in ipairs(Snacks.picker.get({ source = "explorer" })) do
    if not explorer.closed then
      for _, state in pairs(states) do
        if valid(state) and state.explorer == explorer then
          local root = explorer.layout and explorer.layout.root
          if root and root:valid() then
            state.explorer_placement = {
              snapshot = PanelLayout.capture(root.win),
              explorer_win = root.win,
              preferred_width = explorer_preferred_widths[explorer],
            }
            state.detaching_explorer = true
          end
        end
      end
      explorer:close()
      return
    end
  end
end

function M.close_terminal()
  if TerminalTabs.hide() then
    return
  end

  -- Keep the legacy fallback for non-project Snacks terminals. They remain
  -- outside the tab controller and retain their existing PanelClose behavior.
  local current_buf = vim.api.nvim_get_current_buf()
  local fallback
  for _, terminal in ipairs(Snacks.terminal.list()) do
    if terminal:buf_valid() then
      fallback = fallback or terminal
      if terminal.buf == current_buf then
        terminal:hide()
        queue_layout_reflow(80)
        return
      end
    end
  end
  if fallback then
    fallback:hide()
    queue_layout_reflow(80)
  end
end

function M.close_current_panel()
  local current_buf = vim.api.nvim_get_current_buf()
  if states[current_buf] and valid(states[current_buf]) then
    M.close()
    return
  end

  for _, state in pairs(states) do
    local preview = preview_for_buffer(state, current_buf)
    if not preview and state.preview and vim.tbl_contains(state.preview.bufs, current_buf) then
      preview = state.preview
    end
    if preview then
      delete_preview(state, preview)
      if state.editor_win and vim.api.nvim_win_is_valid(state.editor_win) then
        vim.api.nvim_set_current_win(state.editor_win)
      end
      return
    end
  end

  for _, explorer in ipairs(Snacks.picker.get({ source = "explorer" })) do
    if not explorer.closed and explorer_has_buffer(explorer, current_buf) then
      M.close_explorer()
      return
    end
  end

  local managed, root = TerminalTabs.owns_buffer(current_buf)
  if managed then
    TerminalTabs.hide(root)
    return
  end
  for _, terminal in ipairs(Snacks.terminal.list()) do
    if terminal:buf_valid() and terminal.buf == current_buf then
      terminal:hide()
      queue_layout_reflow(80)
      return
    end
  end
  Snacks.notify.info("The current window is not a project panel")
end

-- Bufferline normally opens a clicked buffer in whichever window currently
-- has focus. Redirect it to the central editor so clicking a tab can never
-- replace Explorer, the Git panel, or the terminal.
function M.open_buffer(buf)
  buf = tonumber(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  for _, state in pairs(states) do
    local preview = preview_for_buffer(state, buf)
    if preview and valid(state) then
      local tab = vim.api.nvim_win_get_tabpage(state.win)
      if tab ~= vim.api.nvim_get_current_tabpage() then
        vim.api.nvim_set_current_tabpage(tab)
      end
      activate_preview(state, preview, true)
      return
    end
  end

  local state = current_state()
  if not state then
    local activity = package.loaded["config.activity_bar"]
    local activity_win = activity and activity.editor_window and activity.editor_window() or nil
    if activity_win and vim.api.nvim_win_is_valid(activity_win) then
      vim.api.nvim_win_set_buf(activity_win, buf)
      vim.api.nvim_set_current_win(activity_win)
      return
    end
    local explorer = Snacks.picker.get({ source = "explorer" })[1]
    local main_win = explorer and not explorer.closed and explorer.main or nil
    if main_win and vim.api.nvim_win_is_valid(main_win) then
      vim.api.nvim_win_set_buf(main_win, buf)
      vim.api.nvim_set_current_win(main_win)
    else
      vim.api.nvim_set_current_buf(buf)
    end
    return
  end
  if state.preview_layout then
    hide_preview(state, buf, false)
  else
    local main_win = find_editor_window(state)
    if not main_win or not vim.api.nvim_win_is_valid(main_win) then
      return
    end
    state.last_editor_context = capture_editor_context(main_win)
    vim.api.nvim_win_set_buf(main_win, buf)
    state.editor_win = main_win
    if state.explorer and not state.explorer.closed then
      state.explorer.main = main_win
    end
  end
  if state.editor_win and vim.api.nvim_win_is_valid(state.editor_win) then
    vim.api.nvim_set_current_win(state.editor_win)
  end
end

function M.cycle_buffer(direction)
  local state = current_state()
  if not state then
    local activity = package.loaded["config.activity_bar"]
    local activity_win = activity and activity.editor_window and activity.editor_window() or nil
    if activity_win and vim.api.nvim_win_is_valid(activity_win) then
      vim.api.nvim_win_call(activity_win, function()
        vim.cmd(direction < 0 and "BufferLineCyclePrev" or "BufferLineCycleNext")
      end)
      return
    end
    local explorer = Snacks.picker.get({ source = "explorer" })[1]
    local main_win = explorer and not explorer.closed and explorer.main or nil
    if main_win and vim.api.nvim_win_is_valid(main_win) then
      vim.api.nvim_win_call(main_win, function()
        vim.cmd(direction < 0 and "BufferLineCyclePrev" or "BufferLineCycleNext")
      end)
    else
      vim.cmd(direction < 0 and "BufferLineCyclePrev" or "BufferLineCycleNext")
    end
    return
  end
  local layout = state.preview_layout
  local target_win = layout and layout.after_win and vim.api.nvim_win_is_valid(layout.after_win) and layout.after_win
    or find_editor_window(state)
  if not target_win or not vim.api.nvim_win_is_valid(target_win) then
    return
  end
  vim.api.nvim_win_call(target_win, function()
    vim.cmd(direction < 0 and "BufferLineCyclePrev" or "BufferLineCycleNext")
  end)
end

local function watch_explorer_root(state, explorer)
  local root = explorer and explorer.layout and explorer.layout.root
  if not root or not root:valid() then
    return
  end
  state.explorer_watch_generation = (state.explorer_watch_generation or 0) + 1
  local generation = state.explorer_watch_generation
  vim.api.nvim_create_autocmd("WinClosed", {
    once = true,
    pattern = tostring(root.win),
    callback = function()
      if state.explorer_watch_generation ~= generation then
        return
      end
      if state.detaching_explorer then
        state.detaching_explorer = false
        if state.explorer == explorer then
          state.explorer = nil
        end
        return
      end
      close_preview(state)
      states[state.buf] = nil
      if vim.api.nvim_win_is_valid(state.win) then
        vim.api.nvim_win_close(state.win, true)
      end
    end,
  })
end

local function attach_explorer(state, explorer, attempt)
  if not state or not valid(state) or not explorer or explorer.closed then
    return
  end
  attempt = attempt or 0
  local root = explorer.layout and explorer.layout.root
  if not root or not root:valid() then
    if attempt < 20 then
      vim.defer_fn(function()
        attach_explorer(state, explorer, attempt + 1)
      end, 50)
    end
    return
  end

  state.detaching_explorer = false
  state.explorer = explorer
  if state.editor_win and vim.api.nvim_win_is_valid(state.editor_win) then
    explorer.main = state.editor_win
  else
    state.editor_win = explorer.main
  end
  watch_explorer_root(state, explorer)

  local placement = state.explorer_placement
  if placement then
    local restored = PanelLayout.restore(placement.snapshot, { [placement.explorer_win] = root.win })
    state.explorer_placement = nil
    if restored then
      resize_generation = resize_generation + 1
      explorer_preferred_widths[explorer] = placement.preferred_width or vim.api.nvim_win_get_width(root.win)
    else
      queue_layout_reflow(80)
    end
  end
end

function M.open_explorer(focus)
  local root = LazyVim.root()
  local state = current_state()
  local explorer = Snacks.picker.get({ source = "explorer" })[1]
  if not explorer then
    explorer = Snacks.explorer({ cwd = root })
  end
  disable_explorer_quit(explorer)
  if
    explorer
    and explorer.layout
    and explorer.layout.root
    and explorer.layout.root:valid()
    and not explorer_preferred_widths[explorer]
  then
    explorer_preferred_widths[explorer] = vim.api.nvim_win_get_width(explorer.layout.root.win)
  end
  if state and state.explorer ~= explorer then
    attach_explorer(state, explorer)
  end

  if focus ~= false and explorer and explorer.list and explorer.list.win then
    local win = explorer.list.win.win
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_set_current_win(win)
    end
  end
  return explorer
end

function M.open_git_panel(focus)
  local state = current_state()
  if state then
    if focus ~= false then
      vim.api.nvim_set_current_win(state.win)
    end
    return state
  end

  local explorer = M.open_explorer(false)
  if not explorer then
    return
  end
  state = M.open(explorer, LazyVim.root())
  if focus ~= false then
    local attempts = 0
    local function focus_panel()
      local opened = current_state()
      if opened then
        vim.api.nvim_set_current_win(opened.win)
      elseif attempts < 20 then
        attempts = attempts + 1
        vim.defer_fn(focus_panel, 50)
      end
    end
    focus_panel()
  end
  return state
end

function M.open_terminal(focus)
  return TerminalTabs.open(LazyVim.root(), focus)
end

function M.open_all_panels()
  local explorer = M.open_explorer(false)
  if explorer then
    M.open(explorer, LazyVim.root())
  end
  M.open_terminal(false)

  vim.defer_fn(function()
    local main_win = explorer and explorer.main
    if main_win and vim.api.nvim_win_is_valid(main_win) then
      vim.api.nvim_set_current_win(main_win)
    end
  end, 100)
end

-- Coalesce refresh requests. A single `git commit` makes Git touch its dir
-- several times, so debouncing keeps that down to one `git status`. Requests
-- merge upwards: if anything in the window asked for the commit list too, the
-- one refresh that runs reloads it.
local function queue_refresh(buf, opts)
  local state = states[buf]
  if not valid(state) then
    return
  end
  if opts and opts.full then
    state.refresh_full = true
  end
  state.refresh_request = (state.refresh_request or 0) + 1
  local request = state.refresh_request
  vim.defer_fn(function()
    if valid(state) and state.refresh_request == request then
      local full = state.refresh_full
      state.refresh_full = nil
      M.refresh(buf, { status_only = not full })
    end
  end, 250)
end

local function refresh_all(opts)
  for buf, state in pairs(states) do
    if valid(state) then
      queue_refresh(buf, opts)
    end
  end
end

-- Refresh every open Git panel. Used by callers outside this module, which
-- must not reach into `states` themselves.
function M.refresh_all(opts)
  refresh_all(opts)
end

-- Watch the repository's Git directory.
--
-- Measured with a non-recursive fs_event on the Git dir: editing a tracked
-- file, adding or removing an untracked one, and editing .gitignore produce no
-- events at all -- the watcher only ever reports Git metadata. `git add`
-- reports `index`, `git commit` reports `index` and `COMMIT_EDITMSG`, and
-- `git checkout` reports `index` and `HEAD`. Working-tree changes therefore
-- have to come from the autocmds further down; this covers the other half,
-- Git commands run in the project terminal or in Lazygit.
--
-- `git status` is run with `--no-optional-locks`, which was confirmed not to
-- write to the Git dir, so a refresh cannot trigger itself.
local GIT_DIR_STATUS_ONLY = { index = true }

local function stop_git_watcher(state)
  local handle = state.git_watcher
  state.git_watcher = nil
  if handle and not handle:is_closing() then
    handle:stop()
    handle:close()
  end
end

local function start_git_watcher(state)
  local buf = state.buf
  -- `rev-parse` resolves worktrees and submodules, where `.git` is a file
  -- pointing elsewhere rather than the directory to watch.
  run_git(state.root, { "rev-parse", "--absolute-git-dir" }, function(output, code)
    if code ~= 0 or not valid(state) or state.git_watcher then
      return
    end
    local gitdir = vim.trim(output or "")
    if gitdir == "" or vim.fn.isdirectory(gitdir) ~= 1 then
      return
    end
    local handle = vim.uv.new_fs_event()
    if not handle then
      return
    end
    local started = handle:start(gitdir, {}, function(err, filename)
      if err then
        return
      end
      -- Git writes `<ref>.lock` and renames it into place. Acting on the lock
      -- would read a half-written ref.
      if filename and (filename:match("%.lock$") or filename:match("^%.watchman%-cookie")) then
        return
      end
      -- Only the cheap path is an allow-list: misreading an unknown entry as
      -- expensive costs one `git log`, while the reverse leaves the commit
      -- list stale.
      local full = not (filename and GIT_DIR_STATUS_ONLY[filename])
      vim.schedule(function()
        queue_refresh(buf, { full = full })
      end)
    end)
    if not started then
      handle:close()
      return
    end
    if not valid(state) then
      handle:stop()
      handle:close()
      return
    end
    state.git_watcher = handle
  end)
end

function M.open(explorer, root, attempt, open_opts)
  open_opts = open_opts or {}
  disable_explorer_quit(explorer)
  local existing = current_state()
  if existing then
    return existing
  end

  attempt = attempt or 0
  local target_win = open_opts.target_win
  if target_win and not vim.api.nvim_win_is_valid(target_win) then
    return
  end
  if not target_win and (not explorer or explorer.closed) then
    return
  end
  if not target_win and (not explorer.layout or not explorer.layout.root or not explorer.layout.root:valid()) then
    if attempt < 20 then
      vim.defer_fn(function()
        M.open(explorer, root, attempt + 1, open_opts)
      end, 50)
    end
    return
  end
  if explorer and not explorer_preferred_widths[explorer] then
    explorer_preferred_widths[explorer] = vim.api.nvim_win_get_width(explorer.layout.root.win)
  end

  local marker = vim.fs.find(".git", { path = root, upward = true })[1]
  if not marker then
    return
  end
  local marker_stat = vim.uv.fs_stat(marker)
  if not marker_stat or (marker_stat.type == "directory" and not vim.uv.fs_stat(vim.fs.joinpath(marker, "HEAD"))) then
    return
  end
  root = vim.fs.dirname(marker)

  local buf = vim.api.nvim_create_buf(false, true)
  local win
  if target_win then
    win = target_win
    vim.api.nvim_win_set_buf(win, buf)
  else
    local height = default_git_height()
    win = vim.api.nvim_open_win(buf, false, {
      split = "below",
      win = explorer.layout.root.win,
      height = height,
    })
  end

  vim.api.nvim_buf_set_name(buf, ("project-git://%d/%s"):format(vim.api.nvim_get_current_tabpage(), root))
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "project_git_panel"
  vim.bo[buf].modifiable = false
  vim.wo[win].cursorline = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].statuscolumn = ""
  vim.wo[win].wrap = false
  vim.wo[win].list = false
  vim.wo[win].winfixheight = not target_win
  vim.wo[win].winfixwidth = target_win ~= nil
  -- Text-selection gestures do not belong in the panel: they select words and
  -- lines of the rendered tree and strand it in Visual mode. The panel's own
  -- multi-click mappings below replace the ones that carry an action.
  for _, key in ipairs({
    "<LeftDrag>",
    "<LeftRelease>",
    "<2-LeftDrag>",
    "<3-LeftDrag>",
    "<4-LeftDrag>",
    "<2-LeftRelease>",
    "<3-LeftRelease>",
    "<4-LeftRelease>",
  }) do
    vim.keymap.set({ "n", "i", "x" }, key, "<Nop>", {
      buffer = buf,
      silent = true,
      desc = "No text selection inside project panels",
    })
  end

  local state = {
    buf = buf,
    win = win,
    root = root,
    explorer = explorer,
    editor_win = open_opts.editor_win or (explorer and explorer.main),
    branch = "Git",
    entries = {},
    collapsed = {
      merge = false,
      staged = false,
      changes = false,
      commits = false,
      timeline = false,
    },
    timeline = { generation = 0, offset = 0 },
    expanded = {},
    commit_files = {},
    previews = {},
    preview_serial = 0,
    status_generation = 0,
    commit_generation = 0,
    commit_offset = 0,
    commits_exhausted = false,
    commit_loading = false,
    preview_generation = 0,
  }
  states[buf] = state
  start_git_watcher(state)
  setup_context_menu()
  setup_global_mouse_mappings()
  setup_timeline_tracking()
  sync_hover_events()
  sync_timeline(state)

  local function map(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { buffer = buf, silent = true, desc = desc })
  end
  map("<CR>", function()
    action(state, true)
  end, "Expand commit or preview file")
  -- The buttons and the right-click menu are the mouse's way in; these are the
  -- same three actions for a keyboard, on the row under the cursor.
  for _, item in ipairs({
    { key = "a", action = "stage", desc = "Stage the change under the cursor" },
    { key = "u", action = "unstage", desc = "Unstage the change under the cursor" },
    { key = "x", action = "discard", desc = "Discard the change under the cursor" },
  }) do
    map(item.key, function()
      local entry = state.entries[vim.api.nvim_win_get_cursor(state.win)[1]]
      local allowed, scope = entry_actions(state, entry)
      if allowed and allowed[item.action] then
        activate_action(state, item.action, entry, scope)
      end
    end, item.desc)
  end

  -- Where the terminal reports no pointer movement the cursor row is the one
  -- that shows its buttons, so it has to follow the cursor -- including j/k.
  vim.api.nvim_create_autocmd({ "CursorMoved", "WinEnter" }, {
    buffer = buf,
    callback = function()
      if valid(state) and not state.hover_line then
        follow_active_row(state)
      end
    end,
  })
  local function panel_mouse()
    local mouse = vim.fn.getmousepos()
    if mouse_in_panel_content(state, mouse) then
      return mouse
    end
  end
  local function position_mouse(mouse)
    return position_panel_mouse(state, mouse)
  end

  -- Suppress Neovim's double/triple-click word and line selection everywhere
  -- in the panel content, including the padding below EOF. Perform the action
  -- only when the click really hits a rendered line. Separator clicks still
  -- pass through so native mouse dragging continues to resize the split.
  for _, lhs in ipairs({ "<LeftMouse>", "<2-LeftMouse>", "<3-LeftMouse>", "<4-LeftMouse>" }) do
    local key = lhs
    vim.keymap.set({ "n", "x" }, key, function()
      local mouse = vim.fn.getmousepos()
      if ContextMenu.dismiss(mouse) then
        return ""
      end
      if mouse_in_panel_content(state, mouse) then
        -- An <expr> mapping runs under textlock. Moving the cursor/window here
        -- is illegal on some Neovim versions, so do the panel-local part as
        -- soon as the current input event has finished instead.
        vim.schedule(function()
          if position_mouse(mouse) then
            activate_click(state, mouse)
          end
        end)
        return ""
      end
      -- This buffer-local mapping shadows the global one, so it has to offer
      -- the click to the Activity Bar itself. Without this, the first click on
      -- an Activity Bar icon while the Git panel had focus only moved the
      -- cursor there and a second click was needed to switch views.
      local activity = package.loaded["config.activity_bar"]
      if activity and activity._handle_mouse and activity._handle_mouse(mouse) then
        return ""
      end
      if key ~= "<LeftMouse>" then
        return ""
      end
      queue_terminal_insert(mouse.winid)
      return key
    end, {
      buffer = buf,
      expr = true,
      silent = true,
      desc = "Toggle or open Git panel item",
    })
  end
  vim.keymap.set({ "n", "x" }, "<LeftDrag>", function()
    local mouse = panel_mouse()
    if mouse then
      vim.schedule(function()
        position_mouse(mouse)
      end)
      return ""
    end
    return "<LeftDrag>"
  end, { buffer = buf, expr = true, silent = true, desc = "Position Git panel cursor" })
  vim.keymap.set({ "n", "x" }, "<LeftRelease>", function()
    return panel_mouse() and "" or "<LeftRelease>"
  end, { buffer = buf, expr = true, silent = true, desc = "Toggle or open Git panel item" })
  vim.keymap.set("x", ":", "<Esc>:", {
    buffer = buf,
    silent = false,
    desc = "Open command line without a visual range",
  })
  map("r", function()
    M.refresh(buf)
  end, "Refresh Git panel")
  map("s", function()
    Snacks.picker.git_status({ cwd = root })
  end, "Git status")
  map("l", function()
    Snacks.lazygit.log({ cwd = root })
  end, "Git log")
  map("g", function()
    Snacks.lazygit({ cwd = root })
  end, "Lazygit")
  map("q", "<Nop>", "Disabled in project panels")
  map("<Esc>", "<Nop>", "Disabled in project panels")

  vim.api.nvim_create_autocmd("BufWipeout", {
    once = true,
    buffer = buf,
    callback = function()
      close_preview(state)
      stop_git_watcher(state)
      states[buf] = nil
      sync_hover_events()
      vim.schedule(function()
        if explorer and explorer.layout and explorer.layout:valid() then
          explorer.layout:update()
        end
      end)
    end,
  })
  if explorer then
    watch_explorer_root(state, explorer)
  end

  if explorer then
    explorer.layout:update()
  end
  queue_layout_reflow(80)
  if not target_win then
    local key = placement_key(root, vim.api.nvim_win_get_tabpage(win))
    local placement = git_panel_placements[key]
    if placement then
      local restored = PanelLayout.restore(placement.snapshot, { [placement.panel_win] = win })
      git_panel_placements[key] = nil
      if restored then
        resize_generation = resize_generation + 1
      end
    end
  end
  -- Splitting the Explorer layout while its initial async finder is still
  -- publishing can make Snacks append the same batch twice. Detect that real
  -- UI race after startup and perform one clean finder refresh only when it
  -- actually occurred.
  vim.defer_fn(function()
    if not explorer or not valid(state) or explorer.closed or not explorer.list or not explorer.list.items then
      return
    end
    local seen = {}
    for _, item in ipairs(explorer.list.items) do
      local key = item.file or item.text
      if key and seen[key] then
        explorer:refresh()
        return
      end
      if key then
        seen[key] = true
      end
    end
  end, 200)
  M.refresh(buf)
  return state
end

function M.open_in_window(win, root, editor_win)
  return M.open(nil, root, 0, { target_win = win, editor_win = editor_win })
end

function M.current()
  return current_state()
end

function M.toggle()
  if current_state() then
    M.close()
    return
  end
  local root = LazyVim.root()
  local explorer = Snacks.picker.get({ source = "explorer" })[1]
  if not explorer then
    explorer = Snacks.explorer({ cwd = root })
  end
  if explorer then
    M.open(explorer, root)
  end
end

local group = vim.api.nvim_create_augroup("project_git_panel_refresh", { clear = true })
vim.api.nvim_create_autocmd("WinEnter", {
  group = group,
  callback = function()
    -- Snacks starts insert mode directly from BufEnter. When a mouse click
    -- leaves a prompt/Insert-mode window, the remainder of that input event
    -- can switch the terminal back to Terminal-Normal ("nt") afterwards.
    -- Run once the window transition is complete so one click is enough to
    -- focus the project terminal and send subsequent keys to its job.
    queue_terminal_insert(vim.api.nvim_get_current_win(), { focus = false })
  end,
})
vim.api.nvim_create_autocmd("VimResized", {
  group = group,
  callback = function()
    queue_layout_reflow(80)
  end,
})
-- Working-tree changes never reach the Git dir watcher, so they have to be
-- picked up from editor events instead. FocusGained covers files changed by
-- anything outside Neovim; the terminal events cover commands run in the
-- project terminal, and TermClose doubles as the fallback for Lazygit, which
-- can move HEAD before it exits.
vim.api.nvim_create_autocmd({ "BufWritePost", "FocusGained", "TermLeave" }, {
  group = group,
  callback = function()
    refresh_all()
  end,
})
-- Grow the commit list as it is scrolled: once the viewport comes within a
-- margin of the last line, append the next batch. The panel is a real buffer,
-- so the viewport's own last line is an honest measure of how far down the
-- reader is.
vim.api.nvim_create_autocmd({ "TermClose", "DirChanged" }, {
  group = group,
  callback = function()
    refresh_all({ full = true })
  end,
})
-- GitSignsUpdate only fires for buffers Gitsigns has attached to, so it covers
-- open files alone; GitSignsChanged accompanies its own staging actions.
vim.api.nvim_create_autocmd("User", {
  group = group,
  pattern = { "GitSignsUpdate", "GitSignsChanged" },
  callback = function()
    refresh_all()
  end,
})
-- Last line of defence: whatever was missed, looking at the panel refreshes it.
vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
  group = group,
  callback = function()
    local buf = vim.api.nvim_get_current_buf()
    if states[buf] then
      queue_refresh(buf)
    end
  end,
})

vim.api.nvim_create_autocmd("BufLeave", {
  group = group,
  callback = function(event)
    local win = vim.api.nvim_get_current_win()
    for _, state in pairs(states) do
      local layout, preview = state.preview_layout, state.preview
      if valid(state) and not state.updating_preview and layout and valid_preview(preview) then
        for index, preview_win in ipairs({ layout.main_win, layout.after_win }) do
          if win == preview_win and event.buf == preview.bufs[index] then
            preview.views[index] = vim.api.nvim_win_call(win, vim.fn.winsaveview)
          end
        end
      elseif
        valid(state)
        and not state.updating_preview
        and not state.preview_layout
        and win == state.editor_win
        and event.buf ~= state.buf
        and not preview_containing_buffer(state, event.buf)
      then
        state.last_editor_context = capture_editor_context(win, event.buf)
      end
    end
  end,
})

-- Explorer, :buffer, and Bufferline keyboard commands can all replace a
-- buffer without going through M.open_buffer(). Turn those changes into the
-- same logical tab transition used by mouse clicks.
vim.api.nvim_create_autocmd("BufEnter", {
  group = group,
  callback = function(event)
    local source_win = vim.api.nvim_get_current_win()
    for _, state in pairs(states) do
      if valid(state) and not state.updating_preview then
        local preview = preview_for_buffer(state, event.buf)
        if preview then
          local layout = state.preview_layout
          local already_active = state.preview == preview
            and layout
            and vim.api.nvim_win_is_valid(layout.main_win)
            and vim.api.nvim_win_is_valid(layout.after_win)
            and vim.api.nvim_win_get_buf(layout.main_win) == preview.bufs[1]
            and vim.api.nvim_win_get_buf(layout.after_win) == preview.bufs[2]
          if not already_active then
            vim.schedule(function()
              if valid(state) and valid_preview(preview) then
                activate_preview(state, preview, true)
              end
            end)
          end
        elseif not preview_containing_buffer(state, event.buf) then
          local layout = state.preview_layout
          if
            layout
            and event.buf ~= state.buf
            and (source_win == layout.main_win or source_win == layout.after_win)
          then
            local target_buf = event.buf
            vim.schedule(function()
              if valid(state) and state.preview_layout == layout and vim.api.nvim_buf_is_valid(target_buf) then
                hide_preview(state, target_buf, false)
              end
            end)
          end
        end
      end
    end
  end,
})

M._states = states
M._commit_depths = commit_depths
M._display_path = display_path
M._render = render
M._workspace_path = workspace_path
M._workspace_context_entries = workspace_context_entries
M._open_workspace_file = open_workspace_file
M._context_entry_at_mouse = context_entry_at_mouse
M._entry_buttons = entry_buttons
M._activate_click = activate_click
M._preview_button_hit = preview_button_hit
M._hunk_actions = hunk_actions
M._preview_context_entries = preview_context_entries
M._parse_timeline = parse_timeline
M._load_timeline = load_timeline
M._sync_timeline = sync_timeline
M._follow_active_row = follow_active_row

return M
