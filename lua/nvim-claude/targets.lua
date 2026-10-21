local M = {}
local api = vim.api
local ns = api.nvim_create_namespace('nvim-claude-targets')
local sequence = 0

local function line(buf, row)
  return api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ''
end

local function next_byte(text, col)
  if col >= #text then return #text end
  return vim.fn.byteidx(text, vim.fn.charidx(text, col) + 1)
end

local function nearby(text, col, width, preceding)
  local first, last = col, col
  if preceding then first = math.max(0, col - width)
  else last = math.min(#text, col + width) end
  while first > 0 and text:byte(first + 1) and text:byte(first + 1) >= 128 and text:byte(first + 1) < 192 do first = first - 1 end
  while last < #text and text:byte(last + 1) >= 128 and text:byte(last + 1) < 192 do last = last + 1 end
  return text:sub(first + 1, last)
end

local function content(buf, s, e)
  return table.concat(api.nvim_buf_get_text(buf, s[1], s[2], e[1], e[2], {}), '\n')
end

local function segment(buf, s, e, prefix, suffix, virtual_text)
  sequence = sequence + 1
  local id = api.nvim_buf_set_extmark(buf, ns, s[1], s[2], {
    end_row = e[1], end_col = e[2], right_gravity = true, end_right_gravity = false,
    hl_group = 'Visual', invalidate = true, undo_restore = false,
  })
  return { id = 'target-' .. sequence, mark = id, expected = content(buf, s, e),
    prefix = prefix or '', suffix = suffix or '', selected = virtual_text }
end

function M.positions(target)
  if not api.nvim_buf_is_valid(target.buf) or not api.nvim_buf_is_loaded(target.buf) then return nil, 'Source buffer no longer exists' end
  local positions = {}
  for _, part in ipairs(target.parts) do
    local mark = api.nvim_buf_get_extmark_by_id(target.buf, ns, part.mark, { details = true })
    if #mark == 0 or mark[3].invalid then return nil, 'Target was deleted or invalidated' end
    local s, e = { mark[1], mark[2] }, { mark[3].end_row, mark[3].end_col }
    if not e[1] or s[1] > e[1] or (s[1] == e[1] and s[2] > e[2]) then return nil, 'Invalid target range' end
    if content(target.buf, s, e) ~= part.expected then return nil, 'Target changed while the request was running' end
    if target.generate then
      local text = line(target.buf, s[1])
      if nearby(text, s[2], 16, true) ~= target.before or nearby(text, s[2], 16, false) ~= target.after then
        return nil, 'Insertion boundary changed'
      end
    end
    positions[#positions + 1] = { start = s, finish = e, part = part }
  end
  return positions
end

function M.valid(target, buf)
  return target and target.buf == buf and M.positions(target) ~= nil
end

function M.release(target)
  if target and api.nvim_buf_is_valid(target.buf) then
    for _, part in ipairs(target.parts) do pcall(api.nvim_buf_del_extmark, target.buf, ns, part.mark) end
  end
end

-- Neovim reports partial cells as offsets. Preserve the unselected cells as
-- spaces while replacing only the selected portion of a tab or wide glyph.
local function rectangle(buf, region, selected)
  local a, b = region[1], region[2]
  local row, text = a[2] - 1, line(buf, a[2] - 1)
  local first = math.min(#text, math.max(0, a[3] - 1))
  local last = math.min(#text, math.max(0, b[3] - 1))
  local prefix = string.rep(' ', a[4])
  local suffix = ''
  if last < #text then
    local finish = next_byte(text, last)
    if b[4] > 0 then
      local virtual = vim.fn.strdisplaywidth(text:sub(1, last))
      local width = vim.fn.strdisplaywidth(text:sub(last + 1, finish), virtual)
      suffix = string.rep(' ', math.max(0, width - b[4]))
    end
    last = finish
  end
  return segment(buf, { row, first }, { row, last }, prefix, suffix, selected)
end

function M.capture(buf, visual, generate)
  local target = { buf = buf, parts = {}, generate = generate or false }
  if generate then
    local cursor = api.nvim_win_get_cursor(0)
    local row, col = cursor[1] - 1, cursor[2]
    local text = line(buf, row)
    target.before, target.after = nearby(text, col, 16, true), nearby(text, col, 16, false)
    target.parts[1] = segment(buf, { row, col }, { row, col })
    return target
  end
  local a, b = vim.fn.getpos('v'), vim.fn.getpos('.')
  local mode = visual or vim.fn.mode()
  local options = { type = mode, exclusive = vim.o.selection == 'exclusive', eol = true }
  local regions = vim.fn.getregionpos(a, b, options)
  if mode == '\22' then
    target.block = true
    local texts = vim.fn.getregion(a, b, { type = mode, exclusive = options.exclusive })
    for i, region in ipairs(regions) do
      target.parts[#target.parts + 1] = rectangle(buf, region, texts[i])
    end
  else
    local first, last = regions[1][1], regions[#regions][2]
    local s = { first[2] - 1, math.max(0, first[3] - 1) }
    local e = { last[2] - 1, next_byte(line(buf, last[2] - 1), math.max(0, last[3] - 1)) }
    if mode == 'V' then
      s[2] = 0
      if e[1] + 1 < api.nvim_buf_line_count(buf) then e = { e[1] + 1, 0 }
      else e[2] = #line(buf, e[1]) end
    end
    target.parts[1] = segment(buf, s, e)
  end
  return target
end

function M.serialize(target)
  local positions, reason = M.positions(target)
  if not positions then return nil, reason end
  local result = {}
  for _, p in ipairs(positions) do
    local text = line(target.buf, p.start[1])
    result[#result + 1] = { id = p.part.id, start = p.start, ['end'] = p.finish,
      coordinates = 'zero-based UTF-8 bytes; end-exclusive',
      text = p.part.selected or p.part.expected,
      before = nearby(text, p.start[2], 32, true),
      after = nearby(line(target.buf, p.finish[1]), p.finish[2], 32, false) }
  end
  return result
end

function M.apply(target, replacements)
  local positions, reason = M.positions(target)
  if not positions then return nil, reason end
  if not vim.bo[target.buf].modifiable or vim.bo[target.buf].readonly then return nil, 'Source buffer is not modifiable' end
  local by_id = {}
  for _, replacement in ipairs(replacements) do by_id[replacement.id] = replacement.text end
  -- Validation happens before the first buffer mutation.
  for _, p in ipairs(positions) do
    local text = by_id[p.part.id]
    if type(text) ~= 'string' or (target.block and text:find('[\r\n]')) then return nil, 'Invalid replacement set' end
  end
  local new_parts = {}
  api.nvim_buf_call(target.buf, function()
    -- Break the preceding undo block without joining unrelated user typing.
    local old = vim.bo[target.buf].undolevels
    vim.bo[target.buf].undolevels = old
    for i = #positions, 1, -1 do
      local p = positions[i]
      if i < #positions then vim.cmd('undojoin') end
      local text = p.part.prefix .. by_id[p.part.id] .. p.part.suffix
      local lines = vim.split(text, '\n', { plain = true })
      api.nvim_buf_set_text(target.buf, p.start[1], p.start[2], p.finish[1], p.finish[2], lines)
      local inserted = by_id[p.part.id]
      local start = { p.start[1], p.start[2] + #p.part.prefix }
      local inserted_lines = vim.split(inserted, '\n', { plain = true })
      local finish = { start[1] + #inserted_lines - 1,
        #inserted_lines == 1 and start[2] + #inserted_lines[1] or #inserted_lines[#inserted_lines] }
      new_parts[i] = segment(target.buf, start, finish)
    end
  end)
  M.release(target)
  target.parts, target.generate = new_parts, false
  target.before, target.after = nil, nil
  return true
end

return M
