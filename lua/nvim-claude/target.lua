local M = {}
local ns = vim.api.nvim_create_namespace('nvim-claude-target')
local serial = 0

local function valid(buf) return vim.api.nvim_buf_is_valid(buf) end
local process_identity = tostring((vim.uv or vim.loop).hrtime())
local next_buffer = 0
local function identity(buf)
  local id = vim.b[buf].nvim_claude_target_identity
  if not id then
    next_buffer = next_buffer + 1
    id = process_identity .. '-' .. next_buffer
    vim.b[buf].nvim_claude_target_identity = id
  end
  return id
end
local function line(buf, row) return (vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or '') end
local function text(buf, sr, sc, er, ec)
  return table.concat(vim.api.nvim_buf_get_text(buf, sr, sc, er, ec, {}), '\n')
end
local function at_boundary(s, col)
  if col == 0 or col == #s then return true end
  local byte = s:byte(col + 1)
  return not byte or byte < 128 or byte >= 192
end
local function pos(buf, row, col)
  if row < 0 or row >= vim.api.nvim_buf_line_count(buf) then return nil end
  local s = line(buf, row)
  if col < 0 or col > #s or not at_boundary(s, col) then return nil end
  return { row, col }
end
local function coordinates(buf, start, finish)
  return pos(buf, start[1], start[2]) and pos(buf, finish[1], finish[2])
end
local function mark(buf, a, b)
  return vim.api.nvim_buf_set_extmark(buf, ns, a[1], a[2], {
    right_gravity = false, end_row = b[1], end_col = b[2],
    end_right_gravity = true, hl_group = 'Visual', priority = 160,
  })
end
local function segment(buf, a, b, kind, display_text, prefix, suffix)
  if not coordinates(buf, a, b) then return nil, 'Selection is outside a UTF-8 character' end
  serial = serial + 1
  local before = text(buf, a[1], a[2], b[1], b[2])
  return { id = 'target-' .. serial, start_id = mark(buf, a, b),
    end_id = vim.api.nvim_buf_set_extmark(buf, ns, b[1], b[2], { right_gravity = true }),
    original = before, selected = display_text or before,
    prefix = prefix or '', suffix = suffix or '', kind = kind, row = a[1] }
end
local function bytes_from_chars(str, start, finish)
  local i = vim.str_byteindex(str, start)
  local j = vim.str_byteindex(str, finish)
  return i, j
end
local function inclusive_end(buf, row, col)
  local s = line(buf, row)
  if col >= #s then return #s end
  local char = vim.str_utfindex(s, col)
  return vim.str_byteindex(s, char + 1)
end
local function visual_marks(buf)
  local mode = vim.fn.mode(1)
  local a, b
  if mode == 'v' or mode == 'V' or mode == '\22' then
    a, b = vim.fn.getpos('v'), vim.fn.getpos('.')
  else
    a, b = vim.fn.getpos("'<"), vim.fn.getpos("'>")
  end
  if a[2] == 0 or b[2] == 0 then return nil, 'No active selection' end
  return { a[2] - 1, math.max(0, a[3] - 1), a[4] or 0 },
    { b[2] - 1, math.max(0, b[3] - 1), b[4] or 0 }, mode
end
local function display_cells(s, tabstop)
  local cells, col, chars = {}, 0, vim.fn.strchars(s)
  for i = 0, chars - 1 do
    local a, b = bytes_from_chars(s, i, i + 1)
    local ch = s:sub(a + 1, b)
    local width = ch == '\t' and (tabstop - col % tabstop) or vim.fn.strdisplaywidth(ch)
    if width == 0 and #cells > 0 then
      cells[#cells].b = b
      cells[#cells].ch = cells[#cells].ch .. ch
    else
      cells[#cells + 1] = { a = a, b = b, left = col, right = col + math.max(width, 1), ch = ch }
      col = col + math.max(width, 1)
    end
  end
  return cells, col
end
local function block_segment(buf, row, first, last)
  local s = line(buf, row)
  local cells, width = display_cells(s, vim.bo[buf].tabstop)
  local a, b, prefix, suffix, selected = nil, nil, '', '', {}
  if first >= width then
    -- Virtual columns beyond EOL do not consume existing characters.
    return segment(buf, { row, #s }, { row, #s }, 'block', (' '):rep(last - first),
      (' '):rep(first - width), '')
  end
  for _, cell in ipairs(cells) do
    if cell.right > first and cell.left < last then
      a = a or cell.a; b = cell.b
      local left, right = math.max(first, cell.left), math.min(last, cell.right)
      if cell.ch == '\t' then
        if left > cell.left then prefix = prefix .. (' '):rep(left - cell.left) end
        selected[#selected + 1] = (' '):rep(right - left)
        if right < cell.right then suffix = suffix .. (' '):rep(cell.right - right) end
      else
        -- Neovim treats a wide glyph as an indivisible character in a block.
        -- If the rectangle touches it, include the whole glyph.
        selected[#selected + 1] = cell.ch
      end
    end
  end
  if last > width then selected[#selected + 1] = (' '):rep(last - width) end
  if not a then return segment(buf, { row, #s }, { row, #s }, 'block',
    (' '):rep(last - first), (' '):rep(first - width), '') end
  return segment(buf, { row, a }, { row, b }, 'block', table.concat(selected), prefix, suffix)
end

function M.visual(buf, mode)
  local a, b, captured_mode = visual_marks(buf)
  if not a then return nil, b end
  local selection = mode or (captured_mode == 'v' or captured_mode == 'V' or captured_mode == '\22')
    and captured_mode or vim.fn.visualmode()
  if selection == '\22' then
    local ca = vim.fn.virtcol({ a[1] + 1, a[2] + 1 }) + a[3]
    local cb = vim.fn.virtcol({ b[1] + 1, b[2] + 1 }) + b[3]
    local first, last = math.min(ca, cb) - 1, math.max(ca, cb)
    local items = {}
    for row = math.min(a[1], b[1]), math.max(a[1], b[1]) do
      local item, err = block_segment(buf, row, first, last)
      if not item then M.release({ buf = buf, segments = items }); return nil, err end
      items[#items + 1] = item
    end
    return { buf = buf, identity = identity(buf), segments = items, kind = 'block' }
  end
  if a[1] > b[1] or (a[1] == b[1] and a[2] > b[2]) then a, b = b, a end
  if selection == 'V' then
    a[2] = 0; b[2] = #line(buf, b[1])
  elseif vim.o.selection ~= 'exclusive' then
    b[2] = inclusive_end(buf, b[1], b[2])
  end
  local item, err = segment(buf, a, b, 'replace')
  if not item then return nil, err end
  return { buf = buf, identity = identity(buf), segments = { item }, kind = 'replace' }
end

function M.insertion(buf, insert_mode)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row, col = cursor[1] - 1, cursor[2]
  if not insert_mode then col = math.min(col, #line(buf, row)) end
  local item, err = segment(buf, { row, col }, { row, col }, 'generate')
  if not item then return nil, err end
  return { buf = buf, identity = identity(buf), segments = { item }, kind = 'generate' }
end

local function position(buf, id)
  local p = vim.api.nvim_buf_get_extmark_by_id(buf, ns, id, {})
  return #p == 2 and p or nil
end
function M.inspect(target)
  if not target or not valid(target.buf) then return nil, 'The source buffer was deleted' end
  if target.identity ~= identity(target.buf) then return nil, 'The source buffer was replaced' end
  local found = {}
  for _, item in ipairs(target.segments) do
    local a, b = position(target.buf, item.start_id), position(target.buf, item.end_id)
    if not a or not b or not coordinates(target.buf, a, b) then return nil, 'The target no longer exists' end
    if a[1] > b[1] or (a[1] == b[1] and a[2] > b[2]) then return nil, 'The target positions crossed' end
    local actual = text(target.buf, a[1], a[2], b[1], b[2])
    if actual ~= item.original then return nil, 'The target changed while Claude was responding' end
    if item.kind == 'generate' and (a[1] ~= b[1] or a[2] ~= b[2]) then
      return nil, 'The insertion boundary changed while Claude was responding'
    end
    found[#found + 1] = { start = a, finish = b, item = item }
  end
  return found
end
function M.envelope(target, found)
  local out = {}
  for _, entry in ipairs(found) do
    local a, b, item = entry.start, entry.finish, entry.item
    local row_text = line(target.buf, a[1])
    out[#out + 1] = { id = item.id,
      coordinates = 'zero-based UTF-8 bytes; end-exclusive',
      start = a, ['end'] = b, text = item.selected,
      boundary_before = row_text:sub(math.max(1, a[2] - 63), a[2]),
      boundary_after = line(target.buf, b[1]):sub(b[2] + 1, b[2] + 64) }
  end
  return out
end
function M.release(target)
  if not target or not valid(target.buf) or
    (target.identity and target.identity ~= identity(target.buf)) then return end
  for _, item in ipairs(target.segments) do
    pcall(vim.api.nvim_buf_del_extmark, target.buf, ns, item.start_id)
    pcall(vim.api.nvim_buf_del_extmark, target.buf, ns, item.end_id)
  end
end
function M.apply(target, replacements)
  local entries, err = M.inspect(target)
  if not entries then return nil, err end
  if not vim.bo[target.buf].modifiable then return nil, 'The source buffer is not modifiable' end
  local lookup, count = {}, 0
  for _, replacement in ipairs(replacements) do
    if type(replacement) ~= 'table' or type(replacement.id) ~= 'string' or
      type(replacement.text) ~= 'string' or lookup[replacement.id] ~= nil then
      return nil, 'Invalid or duplicate replacement target'
    end
    lookup[replacement.id] = replacement.text; count = count + 1
  end
  if count ~= #entries then return nil, 'Missing or extra replacement target' end
  for _, entry in ipairs(entries) do
    local item = entry.item
    if lookup[item.id] == nil then return nil, 'Unknown or missing replacement target' end
    if item.kind == 'block' and lookup[item.id]:find('\n', 1, true) then
      return nil, 'Blockwise replacements must stay on their original row'
    end
  end
  if count == 1 and entries[1].item.kind == 'generate' and lookup[entries[1].item.id] == '' then
    return true, 'Empty generation; buffer unchanged'
  end
  -- All validation happens before the first mutation. Bottom-up changes keep
  -- byte coordinates stable; undojoin joins only these synchronous writes.
  local modified = false
  vim.api.nvim_buf_call(target.buf, function()
    for i = #entries, 1, -1 do
      local entry = entries[i]
      local item = entry.item
      local requested = lookup[item.id]
      if not (item.kind == 'block' and item.original == '' and requested == '') then
        local replacement = item.prefix .. requested .. item.suffix
        if replacement ~= item.original then
          local lines = vim.split(replacement, '\n', { plain = true })
          if modified then vim.cmd('silent! undojoin') end
          vim.api.nvim_buf_set_text(target.buf, entry.start[1], entry.start[2],
            entry.finish[1], entry.finish[2], lines)
          modified = true
        end
        item.original, item.selected, item.prefix, item.suffix = replacement, replacement, '', ''
      end
    end
  end)
  return true, not modified and 'Edit completed; buffer unchanged' or nil
end

return M
