local M = {}
local a = vim.api
local ns = a.nvim_create_namespace('nvim-claude-targets')
local serial = 0
local function line(b, r) return a.nvim_buf_get_lines(b, r, r + 1, false)[1] or '' end
local function charlen(s, c)
  local ch = vim.fn.strcharpart(s:sub(c + 1), 0, 1)
  return #ch
end
local function position(t)
  local p = a.nvim_buf_get_extmark_by_id(t.buf, ns, t.mark, { details = true })
  if #p == 0 or p[3].invalid then return nil end
  return p[1], p[2], p[3].end_row, p[3].end_col
end
local function text(t)
  local r, c, er, ec = position(t)
  if not r then return nil end
  return table.concat(a.nvim_buf_get_text(t.buf, r, c, er, ec, {}), '\n')
end
local function mark(b, r, c, er, ec, extra)
  serial = serial + 1
  local t = { buf = b, id = 'target-' .. serial, prefix = '', suffix = '' }
  for k, v in pairs(extra or {}) do t[k] = v end
  t.mark = a.nvim_buf_set_extmark(b, ns, r, c, { end_row = er, end_col = ec,
    right_gravity = false, end_right_gravity = true, invalidate = true, undo_restore = false,
    hl_group = 'Visual' })
  t.original = text(t)
  return t
end
function M.capture(kind, visual)
  local b = a.nvim_get_current_buf()
  local group = { buf = b, segments = {}, block = false, insertion = kind == 'generate' }
  if kind == 'generate' then
    local p = a.nvim_win_get_cursor(0)
    local r, c = p[1] - 1, p[2]
    group.segments = { mark(b, r, c, r, c) }
    local s = line(b, r)
    group.before, group.after = s:sub(math.max(1, c - 31), c), s:sub(c + 1, c + 32)
  elseif visual then
    local mode = vim.fn.mode():sub(1, 1)
    local p, q = vim.fn.getpos('v'), vim.fn.getpos('.')
    local opts = { type = mode, exclusive = vim.o.selection == 'exclusive', eol = true }
    local regions = vim.fn.getregionpos(p, q, opts)
    local selected = vim.fn.getregion(p, q, { type = mode, exclusive = opts.exclusive })
    group.block = mode == '\22'
    if group.block then
      for i, pair in ipairs(regions) do
        local s, e = pair[1], pair[2]
        local r, c = s[2] - 1, math.max(0, s[3] - 1)
        local ln = line(b, r)
        c = math.min(c, #ln)
        local ec = math.min(#ln, math.max(0, e[3] - 1) + charlen(ln, math.max(0, e[3] - 1)))
        local suffix = ''
        if e[4] > 0 and e[3] <= #ln then
          local col = e[3] - 1
          local width = vim.fn.strdisplaywidth(ln:sub(1, col) .. vim.fn.strcharpart(ln:sub(col + 1), 0, 1)) - vim.fn.strdisplaywidth(ln:sub(1, col))
          suffix = string.rep(' ', math.max(0, width - e[4]))
        end
        table.insert(group.segments, mark(b, r, c, r, ec, {
          prefix = string.rep(' ', s[4]), suffix = suffix, selected = selected[i] or '' }))
      end
    else
      local s, e = regions[1][1], regions[#regions][2]
      local r, er = s[2] - 1, e[2] - 1
      local c = mode == 'V' and 0 or math.max(0, s[3] - 1)
      local ec = mode == 'V' and #line(b, er) or math.min(#line(b, er), math.max(0, e[3] - 1) + charlen(line(b, er), math.max(0, e[3] - 1)))
      table.insert(group.segments, mark(b, r, c, er, ec))
    end
    a.nvim_feedkeys(a.nvim_replace_termcodes('<Esc>', true, false, true), 'nx', false)
  else
    error('Select text first')
  end
  a.nvim_buf_attach(b, false, { on_lines = function()
    if group.released then return true end
    if not group.applying and not M.valid(group) then group.invalid = true end
  end, on_detach = function() group.invalid = true end })
  return group
end
function M.valid(g)
  if not g or g.invalid or not a.nvim_buf_is_valid(g.buf) or not a.nvim_buf_is_loaded(g.buf) then return false end
  for _, t in ipairs(g.segments) do
    local ok, current = pcall(text, t)
    if not ok or current ~= t.original then return false end
  end
  if g.insertion then
    local r, c = position(g.segments[1])
    if not r then return false end
    local s = line(g.buf, r)
    if s:sub(math.max(1, c - 31), c) ~= g.before or s:sub(c + 1, c + 32) ~= g.after then return false end
  end
  return true
end
function M.release(g)
  if not g then return end
  g.released = true
  if a.nvim_buf_is_valid(g.buf) then
    for _, t in ipairs(g.segments) do pcall(a.nvim_buf_del_extmark, g.buf, ns, t.mark) end
  end
end
function M.encode(g)
  assert(M.valid(g), 'Target changed; select it again')
  local out = {}
  for _, t in ipairs(g.segments) do
    local r, c, er, ec = position(t)
    table.insert(out, { id = t.id, start = {r,c}, ['end'] = {er,ec}, text = t.selected or t.original,
      coordinates = 'zero-based UTF-8 bytes; end-exclusive', block = g.block,
      before = line(g.buf, r):sub(math.max(1, c - 63), c), after = line(g.buf, er):sub(ec + 1, ec + 64) })
  end
  return out
end
function M.apply(g, replacements)
  assert(M.valid(g), 'Target changed while Claude was answering; result was not applied')
  assert(vim.bo[g.buf].modifiable, 'Source buffer is not modifiable')
  local by_id, count = {}, 0
  for _, item in ipairs(replacements) do
    assert(type(item.id) == 'string' and type(item.text) == 'string' and not by_id[item.id], 'Invalid or duplicate replacement')
    assert(not g.block or not item.text:find('\n', 1, true), 'Block replacements must stay on one row')
    by_id[item.id], count = item.text, count + 1
  end
  assert(count == #g.segments, 'Wrong replacement count')
  for _, t in ipairs(g.segments) do assert(by_id[t.id] ~= nil, 'Missing replacement target') end
  g.applying = true
  local changed = false
  a.nvim_buf_call(g.buf, function()
    -- End any previous insert undo block before the single transaction.
    local ul = vim.bo[g.buf].undolevels
    vim.bo[g.buf].undolevels = ul
    for i = #g.segments, 1, -1 do
      local t = g.segments[i]
      local value = t.prefix .. by_id[t.id] .. t.suffix
      local r, c, er, ec = position(t)
      if value ~= t.original then
        if changed then vim.cmd('undojoin') end
        local lines = vim.split(value, '\n', { plain = true })
        a.nvim_buf_set_text(g.buf, r, c, er, ec, lines)
        a.nvim_buf_del_extmark(g.buf, ns, t.mark)
        local end_row = r + #lines - 1
        local end_col = #lines == 1 and c + #lines[1] or #lines[#lines]
        t.mark = a.nvim_buf_set_extmark(g.buf, ns, r, c, { end_row = end_row, end_col = end_col,
          right_gravity = false, end_right_gravity = true, invalidate = true, undo_restore = false, hl_group = 'Visual' })
        changed = true
      end
      t.original, t.selected, t.prefix, t.suffix = text(t), nil, '', ''
    end
  end)
  g.applying, g.insertion, g.invalid = false, false, false
  return changed
end
return M
