local M = {}

local function call_in_tab(tab, callback, anchor)
  if tab == vim.api.nvim_get_current_tabpage() then
    return callback()
  end
  if not anchor or not vim.api.nvim_win_is_valid(anchor) or vim.api.nvim_win_get_tabpage(anchor) ~= tab then
    anchor = vim.api.nvim_tabpage_list_wins(tab)[1]
  end
  assert(anchor and vim.api.nvim_win_is_valid(anchor), "project panel tab has no usable window")
  return vim.api.nvim_win_call(anchor, callback)
end

local function map_layout(node, replacements)
  if node[1] == "leaf" then
    return { "leaf", replacements[node[2]] or node[2] }
  end
  local mapped = { node[1], {} }
  for _, child in ipairs(node[2]) do
    mapped[2][#mapped[2] + 1] = map_layout(child, replacements)
  end
  return mapped
end

local function leaves(node, result)
  result = result or {}
  if node[1] == "leaf" then
    result[#result + 1] = node[2]
  else
    for _, child in ipairs(node[2]) do
      leaves(child, result)
    end
  end
  return result
end

function M.capture(anchor)
  if not anchor or not vim.api.nvim_win_is_valid(anchor) then
    return
  end
  local tab = vim.api.nvim_win_get_tabpage(anchor)
  return call_in_tab(tab, function()
    local views = {}
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      if vim.api.nvim_win_get_config(win).relative == "" then
        views[win] = vim.api.nvim_win_call(win, vim.fn.winsaveview)
      end
    end
    return {
      tab = tab,
      layout = vim.deepcopy(vim.fn.winlayout()),
      restcmd = vim.fn.winrestcmd(),
      views = views,
    }
  end, anchor)
end

function M.restore(snapshot, replacements)
  replacements = replacements or {}
  if not snapshot or not vim.api.nvim_tabpage_is_valid(snapshot.tab) then
    return false, "panel layout snapshot is no longer valid"
  end
  local target = map_layout(snapshot.layout, replacements)
  local expected = {}
  for _, win in ipairs(leaves(target)) do
    expected[win] = true
  end
  local actual = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(snapshot.tab)) do
    if vim.api.nvim_win_get_config(win).relative == "" then
      actual[win] = true
    end
  end
  if not vim.deep_equal(expected, actual) then
    return false, "panel windows changed while the layout was hidden"
  end

  local anchor = leaves(target)[1]
  local current_win = vim.api.nvim_get_current_win()
  local ok, err = pcall(call_in_tab, snapshot.tab, function()
    local function representative(node)
      if node[1] == "leaf" then
        return node[2]
      end
      return representative(node[2][#node[2]])
    end
    local function rebuild(node)
      if node[1] == "leaf" then
        return
      end
      local representatives = {}
      for index, child in ipairs(node[2]) do
        representatives[index] = representative(child)
      end
      local first = representatives[#representatives]
      for index = #representatives - 1, 1, -1 do
        local result = vim.fn.win_splitmove(representatives[index], first, {
          vertical = node[1] == "row",
          rightbelow = false,
        })
        assert(result == 0, "failed to restore a project panel split")
        first = representatives[index]
      end
      for _, child in ipairs(node[2]) do
        rebuild(child)
      end
    end

    rebuild(target)
    assert(vim.deep_equal(target, vim.fn.winlayout()), "restored project panel layout differs from its snapshot")
    if snapshot.restcmd ~= "" then
      vim.cmd(snapshot.restcmd)
    end
    for old_win, view in pairs(snapshot.views) do
      local win = replacements[old_win] or old_win
      if vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_call, win, function()
          vim.fn.winrestview(view)
        end)
      end
    end
  end, anchor)
  if current_win and vim.api.nvim_win_is_valid(current_win) then
    pcall(vim.api.nvim_set_current_win, current_win)
  end
  return ok, err
end

M._map_layout = map_layout

return M
