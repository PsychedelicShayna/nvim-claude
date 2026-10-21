local M = {}
local ns = vim.api.nvim_create_namespace('nvim-claude-targets')
local tracked, attached, serial = {}, {}, 0
local applying = false
local function less(a, b) return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2]) end
local function equal(a, b) return a[1] == b[1] and a[2] == b[2] end
local function pos(buf, id) return vim.api.nvim_buf_get_extmark_by_id(buf, ns, id, {}) end
local function text(buf, a, b)
  return table.concat(vim.api.nvim_buf_get_text(buf, a[1], a[2], b[1], b[2], {}), '\n')
end
local function attach(buf)
  if attached[buf] then return end
  attached[buf] = true
  vim.api.nvim_buf_attach(buf, false, {
    on_bytes = function(_, _, _, row, col, _, er, ec)
      local a, b = { row, col }, { row + er, er == 0 and col + ec or ec }
      for _, target in ipairs(tracked[buf] or {}) do
        for _, s in ipairs(target.segments) do
          if not applying and not target.invalid then
            local hit = equal(a, b) and (less(s.a, a) and less(a, s.b) or equal(s.a, s.b) and equal(a, s.a))
              or not equal(a, b) and less(a, s.b) and less(s.a, b)
            if hit then target.invalid = true end
          end
          local p, q = pos(buf, s.first), pos(buf, s.last)
          if #p == 2 and #q == 2 then s.a, s.b = p, q else target.invalid = true end
        end
      end
    end,
    on_detach = function() attached[buf], tracked[buf] = nil, nil end,
  })
end
local function segment(buf, a, b, selected, prefix, suffix, block)
  serial = serial + 1
  return {
    id = 'target-' .. serial, a = a, b = b, original = text(buf, a, b), text = selected or text(buf, a, b),
    prefix = prefix or '', suffix = suffix or '', block = block,
    first = vim.api.nvim_buf_set_extmark(buf, ns, a[1], a[2], { right_gravity = true }),
    last = vim.api.nvim_buf_set_extmark(buf, ns, b[1], b[2], { right_gravity = false }),
  }
end
local function register(buf, segments)
  attach(buf)
  local t = { buf = buf, segments = segments }
  tracked[buf] = tracked[buf] or {}
  table.insert(tracked[buf], t)
  return t
end
local function char_end(line, col)
  if col >= #line then return #line end
  local n = col + 1
  while n < #line do
    local byte = line:byte(n + 1)
    if byte < 128 or byte >= 192 then break end
    n = n + 1
  end
  return n
end
function M.generate(buf, cursor)
  local line = vim.api.nvim_buf_get_lines(buf, cursor[1] - 1, cursor[1], false)[1] or ''
  local p = { cursor[1] - 1, math.min(cursor[2], #line) }
  return register(buf, { segment(buf, p, { p[1], p[2] }) })
end
function M.visual(buf, from_command)
  local mode = from_command and vim.fn.visualmode() or vim.fn.mode()
  local p = vim.fn.getpos(from_command and "'<" or 'v')
  local q = vim.fn.getpos(from_command and "'>" or '.')
  local a, b = { p[2] - 1, p[3] - 1 }, { q[2] - 1, q[3] - 1 }
  local exclusive = not from_command and vim.o.selection == 'exclusive'
  local segments = {}
  if mode == '\022' then
    local anchor = vim.fn.virtcol(from_command and "'<" or 'v', true)
    local cursor = vim.fn.virtcol(from_command and "'>" or '.', true)
    local left, right = math.min(anchor[1], cursor[1]) - 1, math.max(anchor[2], cursor[2])
    if exclusive and anchor[1] ~= cursor[1] then
      if anchor[1] < cursor[1] then right = cursor[1] - 1 else left = cursor[2] end
    end
    for row = math.min(a[1], b[1]), math.max(a[1], b[1]) do
      local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
      local byte, cell, startbyte, endbyte, prefix, suffix, selection = 0, 0, nil, nil, '', '', {}
      while byte < #line do
        local finish = char_end(line, byte)
        local ch = line:sub(byte + 1, finish)
        local width = vim.fn.strdisplaywidth(ch, cell)
        if cell < right and cell + width > left then
          startbyte = startbyte or byte
          endbyte = finish
          local before, after = math.max(0, left - cell), math.max(0, cell + width - right)
          if before > 0 then prefix = string.rep(' ', before) end
          if after > 0 then suffix = string.rep(' ', after) end
          if ch == '\t' or before > 0 or after > 0 then
            table.insert(selection, string.rep(' ', width - before - after))
          else table.insert(selection, ch) end
        end
        byte, cell = finish, cell + width
      end
      if not startbyte then startbyte, endbyte, prefix = #line, #line, string.rep(' ', math.max(0, left - cell)) end
      table.insert(segments, segment(buf, { row, startbyte }, { row, endbyte }, table.concat(selection), prefix, suffix, true))
    end
  else
    local reversed = less(b, a)
    if reversed then a, b = b, a end
    local line = vim.api.nvim_buf_get_lines(buf, b[1], b[1] + 1, false)[1] or ''
    if mode == 'V' then
      a[2], b[2] = 0, #line
      if b[1] < vim.api.nvim_buf_line_count(buf) - 1 then b = { b[1] + 1, 0 } end
    elseif exclusive and reversed then
      local firstline = vim.api.nvim_buf_get_lines(buf, a[1], a[1] + 1, false)[1] or ''
      a[2], b[2] = char_end(firstline, a[2]), char_end(line, b[2])
    elseif not exclusive or equal(a, b) then b[2] = char_end(line, b[2]) end
    table.insert(segments, segment(buf, a, b))
  end
  if not from_command then vim.cmd('normal! \27') end
  return register(buf, segments)
end
function M.valid(t)
  if not t or t.invalid or not vim.api.nvim_buf_is_valid(t.buf) then return false end
  for _, s in ipairs(t.segments) do
    local a, b = pos(t.buf, s.first), pos(t.buf, s.last)
    if #a ~= 2 or #b ~= 2 or less(b, a) then return false end
    s.a, s.b = a, b
    if text(t.buf, a, b) ~= s.original then t.invalid = true; return false end
  end
  return true
end
function M.payload(t)
  if not M.valid(t) then return nil end
  local out = {}
  for _, s in ipairs(t.segments) do
    local lines = vim.api.nvim_buf_get_lines(t.buf, s.a[1], s.b[1] + 1, false)
    table.insert(out, { id = s.id, start = s.a, ['end'] = s.b, text = s.text, block = s.block,
      before = (lines[1] or ''):sub(1, s.a[2]), after = (lines[#lines] or ''):sub(s.b[2] + 1) })
  end
  return out
end
function M.highlight(t, on)
  if not t or not vim.api.nvim_buf_is_valid(t.buf) then return end
  for _, s in ipairs(t.segments) do
    if s.highlight then pcall(vim.api.nvim_buf_del_extmark, t.buf, ns, s.highlight); s.highlight = nil end
    if on and M.valid(t) then
      s.highlight = vim.api.nvim_buf_set_extmark(t.buf, ns, s.a[1], s.a[2], {
        end_row = s.b[1], end_col = s.b[2], hl_group = 'Visual', priority = 150,
      })
    end
  end
end
function M.apply(t, replacements)
  if not M.valid(t) then return nil, 'Target changed or source buffer was deleted; result was not applied.' end
  if not vim.bo[t.buf].modifiable or vim.bo[t.buf].readonly then return nil, 'Source buffer is not writable; result was not applied.' end
  local fresh = {}
  applying = true
  local ok, err = pcall(vim.api.nvim_buf_call, t.buf, function()
    -- Break an ongoing Insert undo block before joining this result's segments.
    vim.cmd('let &undolevels = &undolevels')
    for i = #t.segments, 1, -1 do
      local s, value = t.segments[i], replacements[t.segments[i].id]
      local inserted = s.prefix .. value .. s.suffix
      if s.block and value == '' and s.original == '' then inserted = '' end
      if i < #t.segments then vim.cmd('undojoin') end
      vim.api.nvim_buf_set_text(t.buf, s.a[1], s.a[2], s.b[1], s.b[2], vim.split(inserted, '\n', { plain = true }))
      local parts = vim.split(inserted, '\n', { plain = true })
      local last = { s.a[1] + #parts - 1, #parts == 1 and s.a[2] + #parts[1] or #parts[#parts] }
      local first = { s.a[1], s.a[2] }
      if s.block then
        first[2] = first[2] + (inserted == '' and 0 or #s.prefix)
        last[2] = first[2] + #value
      end
      fresh[i] = segment(t.buf, first, last, value, '', '', s.block)
    end
  end)
  applying = false
  if not ok then return nil, tostring(err) end
  t.invalid = true
  return register(t.buf, fresh)
end
return M
