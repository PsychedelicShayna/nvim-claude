local M = {}
local ns = vim.api.nvim_create_namespace('nvim-claude-targets')
local remembered, ask_chain = {}, nil

local function text(buf, start, finish)
  return table.concat(vim.api.nvim_buf_get_text(buf, start[1], start[2], finish[1], finish[2], {}), '\n')
end

local function mark(buf, start, finish, id, block)
  local first = vim.api.nvim_buf_set_extmark(buf, ns, start[1], start[2], {
    right_gravity = true, hl_group = 'Visual', end_row = finish[1], end_col = finish[2],
  })
  local last = vim.api.nvim_buf_set_extmark(buf, ns, finish[1], finish[2], { right_gravity = false })
  return { id = id, first = first, last = last, original = text(buf, start, finish), block = block }
end

local function pos(buf, id)
  local p = vim.api.nvim_buf_get_extmark_by_id(buf, ns, id, {})
  return #p == 2 and p or nil
end

function M.valid(buf, targets)
  if not vim.api.nvim_buf_is_valid(buf) then return false end
  for _, target in ipairs(targets or {}) do
    local start, finish = pos(buf, target.first), pos(buf, target.last)
    if not start or not finish or (start[1] > finish[1]) or (start[1] == finish[1] and start[2] > finish[2]) then return false end
    if text(buf, start, finish) ~= target.original then return false end
  end
  return true
end

local function safe_column(line, col)
  col = math.max(0, math.min(col, #line))
  while col > 0 and col < #line and line:byte(col + 1) >= 128 and line:byte(col + 1) < 192 do col = col - 1 end
  return col
end
function M.wire(buf, targets)
  local result = {}
  for _, target in ipairs(targets) do
    local start, finish = pos(buf, target.first), pos(buf, target.last)
    local start_line = vim.api.nvim_buf_get_lines(buf, start[1], start[1] + 1, false)[1] or ''
    local end_line = vim.api.nvim_buf_get_lines(buf, finish[1], finish[1] + 1, false)[1] or ''
    result[#result + 1] = {
      id = target.id, start = start, ['end'] = finish, text = target.display or target.original,
      block = target.block or nil,
      before = start_line:sub(safe_column(start_line, start[2] - 64) + 1, start[2]),
      after = end_line:sub(finish[2] + 1, safe_column(end_line, finish[2] + 64)),
    }
  end
  return result
end

local function block_span(line, left, right)
  local vcol, byte, first, last, before, after = 1, 0, nil, nil, 0, 0
  local selection = {}
  for index = 0, vim.fn.strchars(line) - 1 do
    local char = vim.fn.strcharpart(line, index, 1)
    local width = vim.fn.strdisplaywidth(char, vcol - 1)
    local ending = vcol + width - 1
    if ending >= left and vcol <= right then
      first = first or byte
      last = byte + #char
      if char == '\t' then
        local selected = math.min(right, ending) - math.max(left, vcol) + 1
        selection[#selection + 1] = string.rep(' ', selected)
        if vcol < left then before = left - vcol end
        if ending > right then after = ending - right end
      else
        selection[#selection + 1] = char
      end
    end
    vcol = ending + 1
    byte = byte + #char
  end
  if not first then first, last, before = #line, #line, math.max(0, left - vcol) end
  return first, last, before, after, table.concat(selection)
end

function M.selection(buf)
  local active = vim.fn.mode():match('^[vV\22]') ~= nil
  local first, last = active and vim.fn.getpos('v') or vim.fn.getpos("'<"),
    active and vim.fn.getpos('.') or vim.fn.getpos("'>")
  local kind = active and vim.fn.mode():sub(1, 1) or vim.fn.visualmode()
  local options = { type = kind, exclusive = vim.o.selection == 'exclusive' }
  local ok, regions = pcall(vim.fn.getregionpos, first, last, options)
  if not ok or #regions == 0 then return nil, 'No visual selection to capture' end
  local targets = {}
  if kind == 'V' then
    local start_row = regions[1][1][2] - 1
    local end_row = regions[#regions][2][2] - 1
    local line = vim.api.nvim_buf_get_lines(buf, end_row, end_row + 1, false)[1] or ''
    return { mark(buf, { start_row, 0 }, { end_row, #line }, 'target-0', false) }
  end
  local block = kind == '\22'
  local left, right
  if block then
    left, right = vim.fn.virtcol(active and 'v' or "'<"), vim.fn.virtcol(active and '.' or "'>")
    if left > right then left, right = right, left end
  end
  for index, pair in ipairs(regions) do
    local a, b = pair[1], pair[2]
    local start_row, end_row = a[2] - 1, b[2] - 1
    local start_line = vim.api.nvim_buf_get_lines(buf, start_row, start_row + 1, false)[1] or ''
    local end_line = vim.api.nvim_buf_get_lines(buf, end_row, end_row + 1, false)[1] or ''
    local start_col = safe_column(start_line, a[3] - 1)
    local end_col = safe_column(end_line, b[3])
    local before, after, display = 0, 0, nil
    if block then start_col, end_col, before, after, display = block_span(start_line, left, right) end
    local target = mark(buf, { start_row, start_col }, { end_row, end_col }, 'target-' .. (index - 1), block)
    target.leftpad, target.rightpad, target.display = before, after, display
    targets[#targets + 1] = target
  end
  return targets
end

function M.insertion(buf, insert_mode)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = vim.api.nvim_buf_get_lines(buf, cursor[1] - 1, cursor[1], false)[1] or ''
  local col = safe_column(line, cursor[2])
  if not insert_mode and col >= #line then col = #line end
  return { mark(buf, { cursor[1] - 1, col }, { cursor[1] - 1, col }, 'target-0', false) }
end

function M.remember(buf, targets)
  remembered[buf] = targets
  ask_chain = nil
end

function M.previous(buf)
  local targets = remembered[buf]
  if targets and M.valid(buf, targets) then return targets end
  remembered[buf] = nil
  return nil
end

function M.ask_selected(buf, targets)
  ask_chain = { buffer = buf, targets = targets }
end

function M.ask_previous(buf)
  if ask_chain and ask_chain.buffer == buf and M.valid(buf, ask_chain.targets) then return ask_chain.targets end
  ask_chain = nil
  return nil
end

function M.content_action()
  ask_chain = nil
end

function M.apply(buf, targets, replacements, transform)
  if not vim.api.nvim_buf_is_valid(buf) or not vim.bo[buf].modifiable or not M.valid(buf, targets) then
    return false, 'Target changed, disappeared, or is not modifiable. The generated result was not applied.'
  end
  local by_id = {}
  for _, item in ipairs(replacements) do by_id[item.id] = transform(item.text) end
  for _, target in ipairs(targets) do
    local replacement = by_id[target.id]
    if type(replacement) ~= 'string' then return false, 'Missing target replacement' end
    if target.block and replacement:find('[\r\n]') then return false, 'Blockwise replacement contains a newline' end
  end
  local ok, err = pcall(function()
    for index = #targets, 1, -1 do
      local target = targets[index]
      local start, finish = pos(buf, target.first), pos(buf, target.last)
      local replacement = by_id[target.id]
      local left = string.rep(' ', target.leftpad or 0)
      local right = string.rep(' ', target.rightpad or 0)
      vim.api.nvim_buf_call(buf, function()
        if index == #targets then vim.cmd('let &undolevels = &undolevels') else vim.cmd('undojoin') end
        vim.api.nvim_buf_set_text(buf, start[1], start[2], finish[1], finish[2],
          vim.split(left .. replacement .. right, '\n', { plain = true }))
      end)
      local begin_col = start[2] + #left
      local end_row = start[1] + select(2, replacement:gsub('\n', ''))
      local end_col = replacement:match('([^\n]*)$')
      end_col = end_row == start[1] and begin_col + #end_col or #end_col
      vim.api.nvim_buf_set_extmark(buf, ns, start[1], begin_col, {
        id = target.first, right_gravity = true, hl_group = 'Visual', end_row = end_row, end_col = end_col,
      })
      vim.api.nvim_buf_set_extmark(buf, ns, end_row, end_col, { id = target.last, right_gravity = false })
      target.original, target.display, target.leftpad, target.rightpad = replacement, nil, 0, 0
    end
  end)
  if not ok then return false, tostring(err) end
  M.remember(buf, targets)
  return true
end

function M.clear(buf, targets)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  for _, target in ipairs(targets or {}) do
    vim.api.nvim_buf_del_extmark(buf, ns, target.first)
    vim.api.nvim_buf_del_extmark(buf, ns, target.last)
  end
end

return M
