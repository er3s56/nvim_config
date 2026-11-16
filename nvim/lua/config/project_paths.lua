local M = {}

function M.root(fallback)
  if rawget(_G, "LazyVim") and LazyVim.root then
    local ok, root = pcall(LazyVim.root)
    if ok and root then
      return vim.fs.normalize(root)
    end
  end
  return vim.fs.normalize(fallback or vim.fn.getcwd())
end

function M.copy(paths, opts)
  opts = opts or {}
  local label = opts.relative and "project-relative path" or "absolute path"
  if opts.relative then
    local root = M.root(opts.cwd)
    paths = vim.tbl_map(function(path)
      return vim.fs.relpath(root, path) or path
    end, paths)
  end
  -- Characterwise: a copied path must not paste a trailing newline into a
  -- shell. Keep selections separated by newlines without adding a final one.
  local ok, err = pcall(vim.fn.setreg, "+", table.concat(paths, "\n"), "c")
  local message = ok and ("Copied " .. label) or ("Failed to copy %s:\n%s"):format(label, tostring(err))
  local level = ok and vim.log.levels.INFO or vim.log.levels.ERROR
  if rawget(_G, "Snacks") and Snacks.notify then
    Snacks.notify(message, { level = level })
  else
    vim.notify(message, level)
  end
end

return M
