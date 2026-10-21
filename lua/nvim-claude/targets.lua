local M = {}
local api = vim.api
local ns = api.nvim_create_namespace('nvim-claude-targets')
local watched = {}
local serial = 0

local function less(a, b)
  return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2])
end
local function equal(a, b) return a[1] == b[1] and a[2] == b[2] end
local function char_start(line, col)
  while col > 0 and col < #line and line:byte(col + 1) >= 128 and line:byte(col + 1) < 192 do
    col = col - 1
  end
  return col
end
local function char_end(line, col)
  if col >= #line then return #line end
  col = char_start(line, col)
  local byte = line:byte(col + 1)
  return math.min(#line, col + (byte < 128 and 1 or byte < 224 and 2 or byte < 240 and 3 or 4))
end
local function text(buf, a, b)
  return table.concat(api.nvim_buf_get_text(buf, a[1], a[2], b[1], b[2], {}), '\n')
end

local function watch(buf)
  if watched[buf] then return end
  watched[buf] = {}
  api.nvim_buf_attach(buf, false, {
    on_bytes = function(_, _, _, row, col, _, oldrow, oldcol, _, newrow, newcol)
      local a = { row, col }
      local b = { row + oldrow, oldrow == 0 and col + oldcol or oldcol }
      local c = { row + newrow, newrow == 0 and col + newcol or newcol }
      local insertion = equal(a, b)
      local function shift(p, right)
        if less(p, a) or (equal(p, a) and not right) then return p end
        if less(b, p) or equal(p, b) then
          return { c[1] + p[1] - b[1], p[1] == b[1] and c[2] + p[2] - b[2] or p[2] }
        end
        return { c[1], c[2] }
      end
      for target in pairs(watched[buf] or {}) do
        if target.valid and not target.applying then
          for _, part in ipairs(target.parts) do
            local s, e = part.start, part.finish
            local touched = insertion and less(s, a) and less(a, e)
              or not insertion and less(a, e) and less(s, b)
            if equal(s, e) and not insertion and not less(s, a) and less(s, b) then touched = true end
            if touched then target.valid = false end
            part.start, part.finish = shift(s, true), shift(e, equal(s, e))
          end
        end
      end
    end,
    on_detach = function()
      for target in pairs(watched[buf] or {}) do target.valid = false end
      watched[buf] = nil
    end,
  })
end

local function add(target, a, b, selected, prefix, suffix)
  local buf = target.buf
  local mark = api.nvim_buf_set_extmark(buf, ns, a[1], a[2], {
    end_row = b[1], end_col = b[2], right_gravity = true,
    end_right_gravity = equal(a, b), undo_restore = false, invalidate = true,
    hl_group = 'NvClaudeTarget', hl_mode = 'combine',
  })
  serial = serial + 1
  target.parts[#target.parts + 1] = {
    id = 'target-' .. serial, mark = mark, start = a, finish = b,
    original = text(buf, a, b), selected = selected or text(buf, a, b),
    prefix = prefix or '', suffix = suffix or '',
  }
end

function M.create(buf, ranges, kind)
  watch(buf)
  local target = { buf = buf, parts = {}, valid = true, kind = kind or 'v' }
  watched[buf][target] = true
  for _, range in ipairs(ranges) do
    add(target, range.start, range.finish, range.text, range.prefix, range.suffix)
  end
  return target
end

function M.release(target)
  if not target then return end
  if watched[target.buf] then watched[target.buf][target] = nil end
  if api.nvim_buf_is_valid(target.buf) then
    for _, p in ipairs(target.parts) do pcall(api.nvim_buf_del_extmark, target.buf, ns, p.mark) end
  end
end

function M.positions(target)
  if not target or not target.valid or not api.nvim_buf_is_loaded(target.buf) then
    return nil, 'The captured target is no longer valid'
  end
  local positions = {}
  for _, part in ipairs(target.parts) do
    local mark = api.nvim_buf_get_extmark_by_id(target.buf, ns, part.mark, { details = true })
    if #mark == 0 or mark[3].invalid then
      target.valid = false
      return nil, 'The captured target was deleted or undone'
    end
    local a, b = { mark[1], mark[2] }, { mark[3].end_row, mark[3].end_col }
    if text(target.buf, a, b) ~= part.original then
      target.valid = false
      return nil, 'Text inside the captured target changed'
    end
    part.start, part.finish = a, b
    positions[#positions + 1] = { start = a, finish = b, part = part }
  end
  return positions
end

function M.visual()
  local buf, mode = api.nvim_get_current_buf(), vim.fn.mode()
  local first, last = vim.fn.getpos('v'), vim.fn.getpos('.')
  first[1], last[1] = buf, buf
  local opts = { type = mode, exclusive = vim.o.selection == 'exclusive', eol = true }
  local regions = vim.fn.getregionpos(first, last, opts)
  local selected = vim.fn.getregion(first, last, { type = mode, exclusive = opts.exclusive })
  if #regions == 0 then error('No Visual selection') end
  local ranges = {}
  if mode:sub(1, 1) == '\22' then
    for i, region in ipairs(regions) do
      local s, e = region[1], region[2]
      local row = s[2] - 1
      local line = api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
      local sc = char_start(line, math.min(#line, math.max(0, s[3] - 1)))
      local ec = char_start(line, math.min(#line, math.max(0, e[3] - 1)))
      local ending = char_end(line, ec)
      local prefix, suffix = string.rep(' ', s[4]), ''
      if e[4] > 0 and ec < #line then
        local char = line:sub(ec + 1, ending)
        local width = char == '\t' and (vim.bo[buf].tabstop - vim.fn.strdisplaywidth(line:sub(1, ec)) % vim.bo[buf].tabstop)
          or vim.fn.strdisplaywidth(char)
        suffix = string.rep(' ', math.max(0, width - e[4]))
      end
      ranges[#ranges + 1] = { start = { row, sc }, finish = { row, ending },
        text = selected[i], prefix = prefix, suffix = suffix }
    end
  else
    local s, e = regions[1][1], regions[#regions][2]
    local row = e[2] - 1
    local line = api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
    local ending = char_end(line, math.max(0, e[3] - 1))
    ranges[1] = { start = { s[2] - 1, math.max(0, s[3] - 1) }, finish = { row, ending } }
  end
  return M.create(buf, ranges, mode)
end

function M.insertion()
  local pos = api.nvim_win_get_cursor(0)
  local point = { pos[1] - 1, pos[2] }
  return M.create(api.nvim_get_current_buf(), { { start = point, finish = point } }, 'insert')
end

function M.envelope(target)
  local positions, err = M.positions(target)
  if not positions then return nil, err end
  local result = {}
  for _, p in ipairs(positions) do
    local line = api.nvim_buf_get_lines(target.buf, p.start[1], p.start[1] + 1, false)[1]
    local end_line = api.nvim_buf_get_lines(target.buf, p.finish[1], p.finish[1] + 1, false)[1]
    result[#result + 1] = { id = p.part.id, start = p.start, ['end'] = p.finish,
      text = p.part.selected, coordinates = 'zero-based UTF-8 bytes; end-exclusive',
      blockwise = target.kind:sub(1, 1) == '\22',
      boundary = { before = line:sub(char_start(line, math.max(0, p.start[2] - 80)) + 1, p.start[2]),
        after = end_line:sub(p.finish[2] + 1, char_end(end_line, math.min(#end_line, p.finish[2] + 80))) },
    }
  end
  return result
end

function M.clone(target)
  local positions, err = M.positions(target)
  if not positions then return nil, err end
  local ranges = {}
  for _, p in ipairs(positions) do
    ranges[#ranges + 1] = { start = p.start, finish = p.finish, text = p.part.selected,
      prefix = p.part.prefix, suffix = p.part.suffix }
  end
  local copy = M.create(target.buf, ranges, target.kind)
  -- A request keeps the same IDs as the captured target.
  for i, p in ipairs(copy.parts) do p.id = target.parts[i].id end
  return copy
end

function M.apply(target, replacements)
  local positions, err = M.positions(target)
  if not positions then return nil, err end
  if not vim.bo[target.buf].modifiable then
    return nil, 'The captured buffer is not modifiable'
  end
  local by_id = {}
  for _, r in ipairs(replacements) do by_id[r.id] = r.text end
  if #replacements ~= #positions then return nil, 'Replacement count mismatch' end
  for _, p in ipairs(positions) do
    if type(by_id[p.part.id]) ~= 'string' then return nil, 'Replacement ID mismatch' end
    if target.kind:sub(1, 1) == '\22' and by_id[p.part.id]:find('[\r\n]') then
      return nil, 'Blockwise replacement contains a newline'
    end
  end
  target.applying = true
  local new_ranges = {}
  local ok, failure = pcall(api.nvim_buf_call, target.buf, function()
    -- A new API edit starts a new undo block; only the remaining rectangle rows join it.
    vim.cmd('let &undolevels = &undolevels')
    for i = #positions, 1, -1 do
      local p = positions[i]
      if i < #positions then vim.cmd('undojoin') end
      local replacement = by_id[p.part.id]
      local applied = p.part.prefix .. replacement .. p.part.suffix
      local chunks = vim.split(applied, '\n', { plain = true })
      if target.kind == 'V' then
        if chunks[#chunks] == '' and #chunks > 1 then table.remove(chunks) end
        if applied == '' then chunks = {} end
        api.nvim_buf_set_lines(target.buf, p.start[1], p.finish[1] + 1, false, chunks)
        local count = #chunks
        local finish = count == 0 and { p.start[1], 0 }
          or { p.start[1] + count - 1, #chunks[count] }
        if finish[1] >= api.nvim_buf_line_count(target.buf) then
          finish = { api.nvim_buf_line_count(target.buf) - 1, #(api.nvim_buf_get_lines(target.buf, -2, -1, false)[1] or '') }
        end
        new_ranges[i] = { start = count == 0 and finish or { p.start[1], 0 }, finish = finish }
      else
        api.nvim_buf_set_text(target.buf, p.start[1], p.start[2], p.finish[1], p.finish[2], chunks)
        local output = vim.split(replacement, '\n', { plain = true })
        local start = { p.start[1], p.start[2] + #p.part.prefix }
        local finish = { start[1] + #output - 1, #output == 1 and start[2] + #output[1] or #output[#output] }
        new_ranges[i] = { start = start, finish = finish }
      end
    end
  end)
  target.applying = false
  if not ok then return nil, tostring(failure) end
  return M.create(target.buf, new_ranges, target.kind == 'V' and 'v' or target.kind)
end

return M
