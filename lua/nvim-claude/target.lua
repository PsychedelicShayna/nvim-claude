local M = {}
local ns = vim.api.nvim_create_namespace('nvim-claude-target')
local remembered = {}
local serial = 0

local function lines(buf) return vim.api.nvim_buf_get_lines(buf, 0, -1, false) end
local function slice(buf, sr, sc, er, ec)
  return table.concat(vim.api.nvim_buf_get_text(buf, sr, sc, er, ec, {}), '\n')
end
local function boundary(line, col)
  if col >= #line then return #line end
  while col > 0 and line:byte(col + 1) >= 128 and line:byte(col + 1) < 192 do col = col - 1 end
  return col
end
local function end_boundary(line, col)
  if col >= #line then return #line end
  while col < #line and line:byte(col + 1) >= 128 and line:byte(col + 1) < 192 do col = col + 1 end
  return col
end
local function mark(buf, sr, sc, er, ec)
  serial = serial + 1
  local id = 'target-' .. serial
  local ext = vim.api.nvim_buf_set_extmark(buf, ns, sr, sc, {
    end_row = er, end_col = ec, right_gravity = false, end_right_gravity = true,
    hl_group = 'Visual', priority = 150,
  })
  return { id = id, mark = ext, text = slice(buf, sr, sc, er, ec), start = { sr, sc }, finish = { er, ec } }
end

function M.capture(op, visual, insert)
  local buf = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  if not vim.bo[buf].modifiable and op ~= 'ask' then return nil, 'Buffer is not modifiable' end
  local result = { buf = buf, win = win, operation = op, targets = {}, block = false }
  if visual then
    local a, b = vim.fn.getpos("'<"), vim.fn.getpos("'>")
    local mode = vim.fn.visualmode()
    if a[2] < 1 or b[2] < 1 then return nil, 'Select text first' end
    local sr, er = math.min(a[2], b[2]) - 1, math.max(a[2], b[2]) - 1
    local content = lines(buf)
    if mode == '\22' then
      result.block = true
      local left = math.min(vim.fn.virtcol("'<"), vim.fn.virtcol("'>"))
      local right = math.max(vim.fn.virtcol("'<"), vim.fn.virtcol("'>"))
      for row = sr, er do
        local line = content[row + 1] or ''
        local first, last, prefix, suffix = nil, nil, '', ''
        local selected = {}
        local width = 0
        local chars = vim.fn.strchars(line)
        for index = 0, chars - 1 do
          local from = vim.fn.byteidx(line, index)
          local to = vim.fn.byteidx(line, index + 1)
          local char = line:sub(from + 1, to)
          local next_width = vim.fn.strdisplaywidth(line:sub(1, to))
          local begin_col, end_col = width + 1, next_width
          if end_col >= left and begin_col <= right then
            first = first or from
            last = to
            local overlap_left, overlap_right = math.max(begin_col, left), math.min(end_col, right)
            if char == '\t' then
              if #selected == 0 then prefix = string.rep(' ', overlap_left - begin_col) end
              selected[#selected + 1] = string.rep(' ', overlap_right - overlap_left + 1)
              suffix = string.rep(' ', end_col - overlap_right)
            else
              selected[#selected + 1] = char
              suffix = ''
            end
          end
          width = next_width
        end
        if first then
          local item = mark(buf, row, first, row, last)
          item.selected = table.concat(selected)
          item.prefix, item.suffix = prefix, suffix
          result.targets[#result.targets + 1] = item
        else
          local item = mark(buf, row, #line, row, #line)
          item.selected = ''
          item.prefix = string.rep(' ', math.max(0, left - width - 1))
          item.suffix = ''
          result.targets[#result.targets + 1] = item
        end
      end
    else
      local sc, ec
      if mode == 'V' then
        sc, ec = 0, #(content[er + 1] or '')
      else
        local start_pos, end_pos = a, b
        if a[2] > b[2] or (a[2] == b[2] and a[3] > b[3]) then start_pos, end_pos = b, a end
        sc = boundary(content[sr + 1], math.max(start_pos[3] - 1, 0))
        ec = end_boundary(content[er + 1], math.min(end_pos[3], #(content[er + 1] or '')))
      end
      result.targets[1] = mark(buf, sr, sc, er, ec)
    end
    if #result.targets == 0 then return nil, 'Selection has no text' end
  elseif op == 'replace' or op == 'previous' then
    local previous = remembered[buf]
    if not previous or not M.valid(previous) then return nil, 'Select text first; no valid remembered target' end
    result.targets = previous.targets
    result.block = previous.block
  elseif op == 'generate' then
    local cursor = vim.api.nvim_win_get_cursor(win)
    local row, col = cursor[1] - 1, cursor[2]
    if insert then col = vim.fn.col('.') - 1 end
    result.targets[1] = mark(buf, row, col, row, col)
  end
  return result
end

function M.valid(capture)
  if not vim.api.nvim_buf_is_valid(capture.buf) then return false end
  for _, target in ipairs(capture.targets) do
    local ok, pos = pcall(vim.api.nvim_buf_get_extmark_by_id, capture.buf, ns, target.mark, { details = true })
    if not ok or #pos == 0 then return false end
    local detail = pos[3]
    if slice(capture.buf, pos[1], pos[2], detail.end_row, detail.end_col) ~= target.text then return false end
  end
  return true
end

function M.payload(capture)
  local targets = {}
  for _, target in ipairs(capture.targets) do
    local pos = vim.api.nvim_buf_get_extmark_by_id(capture.buf, ns, target.mark, { details = true })
    targets[#targets + 1] = { id = target.id, coordinates = 'zero-based UTF-8 bytes; end-exclusive',
      start = { pos[1], pos[2] }, ['end'] = { pos[3].end_row, pos[3].end_col },
      text = target.selected or target.text }
  end
  return targets
end

function M.apply(capture, replacements)
  if not vim.api.nvim_buf_is_valid(capture.buf) or not vim.bo[capture.buf].modifiable or not M.valid(capture) then
    return false, 'Target changed or source buffer is no longer editable'
  end
  local by_id = {}
  if type(replacements) ~= 'table' or #replacements ~= #capture.targets then return false, 'Wrong replacement count' end
  for _, item in ipairs(replacements) do
    if type(item) ~= 'table' or type(item.id) ~= 'string' or type(item.text) ~= 'string' or by_id[item.id] then
      return false, 'Invalid or duplicate replacement'
    end
    if capture.block and item.text:find('\n', 1, true) then return false, 'Block replacements must stay on one row' end
    by_id[item.id] = item.text
  end
  for _, target in ipairs(capture.targets) do
    if by_id[target.id] == nil then return false, 'Missing replacement ' .. target.id end
  end
  local applied = {}
  for index = #capture.targets, 1, -1 do
    local target = capture.targets[index]
    local pos = vim.api.nvim_buf_get_extmark_by_id(capture.buf, ns, target.mark, { details = true })
    local text = (target.prefix or '') .. by_id[target.id] .. (target.suffix or '')
    vim.api.nvim_buf_call(capture.buf, function()
      if index < #capture.targets then vim.cmd('silent! undojoin') end
      vim.api.nvim_buf_set_text(capture.buf, pos[1], pos[2], pos[3].end_row, pos[3].end_col,
        vim.split(text, '\n', { plain = true }))
    end)
    applied[index] = { start = { pos[1], pos[2] }, text = text }
  end
  -- Extmarks of replacement ranges have changed; pin the inserted text anew.
  local next_targets = {}
  for index, item in ipairs(applied) do
    local parts = vim.split(item.text, '\n', { plain = true })
    local er = item.start[1] + #parts - 1
    local ec = #parts == 1 and item.start[2] + #parts[1] or #parts[#parts]
    next_targets[index] = mark(capture.buf, item.start[1], item.start[2], er, ec)
  end
  remembered[capture.buf] = { buf = capture.buf, targets = next_targets, block = capture.block }
  return true
end

function M.remember(capture)
  remembered[capture.buf] = capture
end

function M.clear(buf)
  remembered[buf] = nil
end

return M
