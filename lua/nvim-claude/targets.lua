local M = {}
local ns = vim.api.nvim_create_namespace('nvim-claude-targets')
local remembered = {}
local selected_ask = nil
local last_action = nil

local function lines(buf) return vim.api.nvim_buf_get_lines(buf, 0, -1, false) end
local function valid(target)
  if not target or not vim.api.nvim_buf_is_valid(target.buf) then return false end
  for _, segment in ipairs(target.segments) do
    local mark = vim.api.nvim_buf_get_extmark_by_id(target.buf, ns, segment.mark, { details = true })
    if #mark == 0 then return false end
    local detail = mark[3]
    if not detail or detail.end_row == nil then return false end
    local content = vim.api.nvim_buf_get_text(target.buf, mark[1], mark[2], detail.end_row, detail.end_col, {})
    if table.concat(content, '\n') ~= segment.text then return false end
  end
  return true
end

local function add(buf, sr, sc, er, ec, id, block)
  local text = table.concat(vim.api.nvim_buf_get_text(buf, sr, sc, er, ec, {}), '\n')
  local mark = vim.api.nvim_buf_set_extmark(buf, ns, sr, sc, { end_row = er, end_col = ec,
    right_gravity = false, end_right_gravity = true, hl_group = 'Visual' })
  return { id = id, mark = mark, text = text, block = block }
end

local function char_end(line, byte)
  byte = math.min(byte, #line)
  if byte == #line then return byte end
  local first = line:byte(byte + 1)
  if first < 128 then return byte + 1 end
  if first < 224 then return byte + 2 end
  if first < 240 then return byte + 3 end
  return byte + 4
end

local function aligned(line, byte)
  byte = math.min(byte, #line)
  while byte > 0 and byte < #line and line:byte(byte + 1) >= 128 and line:byte(byte + 1) < 192 do
    byte = byte - 1
  end
  return byte
end

local function block_cells(line, left, right, tabstop)
  local cells, col, start_byte, stop_byte = {}, 0, nil, nil
  local prefix, suffix = '', ''
  local index = 1
  while index <= #line do
    local ch = vim.fn.strcharpart(line:sub(index), 0, 1)
    local width = ch == '\t' and tabstop - col % tabstop or vim.fn.strdisplaywidth(ch)
    width = math.max(width, 1)
    if col < right and col + width > left then
      start_byte = start_byte or index - 1
      stop_byte = index - 1 + #ch
      local overlap_l, overlap_r = math.max(col, left), math.min(col + width, right)
      if overlap_l > col then prefix = string.rep(' ', overlap_l - col) end
      if ch == '\t' or overlap_l > col or overlap_r < col + width then
        cells[#cells + 1] = string.rep(' ', overlap_r - overlap_l)
      else cells[#cells + 1] = ch end
      if overlap_r < col + width then suffix = string.rep(' ', col + width - overlap_r) end
    end
    col = col + width
    index = index + #ch
  end
  if not start_byte then return #line, #line, '', '', '', math.max(0, left - col) end
  return start_byte, stop_byte, table.concat(cells), prefix, suffix, 0
end

function M.capture(operation, visual)
  local buf = vim.api.nvim_get_current_buf()
  local target = { buf = buf, segments = {}, operation = operation, block = false }
  if visual then
    local mode = vim.fn.mode()
    local a, b = vim.fn.getpos('v'), vim.fn.getpos('.')
    local rows = lines(buf)
    if mode == '\22' then
      local left, right = math.min(vim.fn.virtcol('v'), vim.fn.virtcol('.')) - 1,
        math.max(vim.fn.virtcol('v'), vim.fn.virtcol('.'))
      target.block = true
      for row = math.min(a[2], b[2]), math.max(a[2], b[2]) do
        local line = rows[row] or ''
        local sc, ec, expanded, prefix, suffix, pad = block_cells(line, left, right, vim.bo[buf].tabstop)
        local seg = add(buf, row - 1, sc, row - 1, ec, 'target-' .. (#target.segments), true)
        seg.text, seg.expanded, seg.prefix, seg.suffix, seg.pad =
          line:sub(sc + 1, ec), expanded, prefix, suffix, pad
        target.segments[#target.segments + 1] = seg
      end
    else
      local sr, er = math.min(a[2], b[2]) - 1, math.max(a[2], b[2]) - 1
      local sc, ec
      if mode == 'V' then
        sc = 0; ec = #(rows[er + 1] or '')
      else
        local p, q = a, b
        if a[2] > b[2] or a[2] == b[2] and a[3] > b[3] then p, q = b, a end
        sc = aligned(rows[sr + 1], p[3] - 1)
        ec = aligned(rows[er + 1], q[3] - 1)
        ec = vim.o.selection == 'exclusive' and ec or char_end(rows[er + 1], ec)
      end
      target.segments[1] = add(buf, sr, sc, er, ec, 'target-0', false)
    end
  elseif operation == 'generate' then
    local cursor = vim.api.nvim_win_get_cursor(0)
    local line = vim.api.nvim_buf_get_lines(buf, cursor[1] - 1, cursor[1], false)[1]
    local col = aligned(line, cursor[2])
    target.segments[1] = add(buf, cursor[1] - 1, col, cursor[1] - 1, col, 'target-0', false)
  else return nil end
  if operation == 'replace' then remembered[buf] = target; last_action = 'replace'
  elseif operation == 'ask' then selected_ask = target; last_action = 'selected_ask'
  else last_action = 'generate' end
  return target
end

function M.previous(buf, ask)
  local target = ask and selected_ask or remembered[buf]
  if target and target.buf == buf and valid(target) and (not ask or last_action == 'selected_ask') then return target end
  return nil
end

function M.general_ask() last_action = 'ask'; selected_ask = nil end
function M.valid(target) return valid(target) end

function M.envelope(target)
  local result = {}
  for _, seg in ipairs(target.segments) do
    local pos = vim.api.nvim_buf_get_extmark_by_id(target.buf, ns, seg.mark, { details = true })
    local detail = pos[3]
    result[#result + 1] = { id = seg.id, coordinates = 'zero-based UTF-8 bytes; end-exclusive',
      start = { pos[1], pos[2] }, ['end'] = { detail.end_row, detail.end_col },
      text = seg.expanded or seg.text }
  end
  return result
end

local function split(text)
  return vim.split(text, '\n', { plain = true })
end

function M.apply(target, replacements)
  if not valid(target) then return false, 'Target changed while Claude was responding' end
  if not vim.bo[target.buf].modifiable then return false, 'Source buffer is not modifiable' end
  local expected = {}
  for _, seg in ipairs(target.segments) do expected[seg.id] = seg end
  local count = 0
  for _, replacement in ipairs(replacements) do
    local seg = expected[replacement.id]
    if not seg or seg.replacement ~= nil or type(replacement.text) ~= 'string' then return false, 'Invalid replacement IDs or text' end
    if target.block and replacement.text:find('\n', 1, true) then return false, 'Block replacement crosses a row' end
    seg.replacement = replacement.text
    count = count + 1
  end
  if count ~= #target.segments then return false, 'Missing replacement target' end
  local changed = false
  for index = #target.segments, 1, -1 do
    local seg = target.segments[index]
    local pos = vim.api.nvim_buf_get_extmark_by_id(target.buf, ns, seg.mark, { details = true })
    local detail = pos[3]
    local inserted = seg.replacement
    if target.block then
      -- Only split intersected tabs/wide glyphs; unselected visual cells survive.
      inserted = seg.prefix .. inserted .. seg.suffix
      if seg.pad > 0 and seg.replacement ~= '' then inserted = string.rep(' ', seg.pad) .. inserted end
    end
    if changed then vim.cmd('undojoin') end
    vim.api.nvim_buf_set_text(target.buf, pos[1], pos[2], detail.end_row, detail.end_col, split(inserted))
    changed = true
    local end_row = pos[1] + select(2, inserted:gsub('\n', ''))
    local end_col = end_row == pos[1] and pos[2] + #inserted or #(split(inserted)[#split(inserted)])
    vim.api.nvim_buf_del_extmark(target.buf, ns, seg.mark)
    seg.mark = vim.api.nvim_buf_set_extmark(target.buf, ns, pos[1], pos[2], {
      end_row = end_row, end_col = end_col, right_gravity = false, end_right_gravity = true })
    seg.text, seg.expanded, seg.replacement = inserted, nil, nil
  end
  if target.operation == 'replace' then remembered[target.buf] = target end
  return true
end

return M
