local M = {}
local api = vim.api
local ns = api.nvim_create_namespace('nvim-claude-targets')
local watched, targets = {}, {}
local applying = false

local function line(buf, row)
  return api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ''
end

local function nextbyte(text, col)
  if col >= #text then return #text end
  local c = text:byte(col + 1)
  return math.min(#text, col + (c < 128 and 1 or c < 224 and 2 or c < 240 and 3 or 4))
end

local function position(buf, id)
  local p = api.nvim_buf_get_extmark_by_id(buf, ns, id, { details = true })
  if #p == 0 then return nil end
  return { p[1], p[2], p[3].end_row, p[3].end_col }
end

local function text_at(buf, p)
  return table.concat(api.nvim_buf_get_text(buf, p[1], p[2], p[3], p[4], {}), '\n')
end

local function less(a, b, c, d) return a < c or (a == c and b < d) end

local function watch(buf)
  if watched[buf] then return end
  watched[buf] = true
  api.nvim_buf_attach(buf, false, {
    on_bytes = function(_, b, _, sr, sc, _, er, ec, _, nr, nc)
      local old_er, old_ec = sr + er, er == 0 and sc + ec or ec
      for _, target in pairs(targets[b] or {}) do
        if not applying then
          for _, segment in ipairs(target.segments) do
            local p = segment.last
            if p then
              local insertion = sr == old_er and sc == old_ec
              local intersects = insertion and less(p[1], p[2], sr, sc) and less(sr, sc, p[3], p[4])
                or not insertion and less(sr, sc, p[3], p[4]) and less(p[1], p[2], old_er, old_ec)
              if intersects then target.invalid = true end
            end
          end
        end
        for _, segment in ipairs(target.segments) do
          segment.last = position(b, segment.mark)
        end
      end
    end,
    on_detach = function(_, b)
      for _, target in pairs(targets[b] or {}) do target.invalid = true end
      targets[b], watched[b] = nil, nil
    end,
  })
end

local function mark(target, sr, sc, er, ec, selected, prefix, suffix)
  local options = { end_row = er, end_col = ec, right_gravity = true, end_right_gravity = false,
    hl_group = 'Visual', strict = false, undo_restore = false }
  if sr == er and sc == ec then options.end_right_gravity = true end
  local id = api.nvim_buf_set_extmark(target.buf, ns, sr, sc, options)
  local p = { sr, sc, er, ec }
  target.segments[#target.segments + 1] = { mark = id, last = p, expected = text_at(target.buf, p),
    selected = selected, prefix = prefix or '', suffix = suffix or '', id = 'target-' .. #target.segments }
end

function M.capture(kind, visual)
  local buf = api.nvim_get_current_buf()
  local target = { buf = buf, origin = api.nvim_get_current_win(), segments = {}, kind = kind }
  watch(buf)
  targets[buf] = targets[buf] or {}
  table.insert(targets[buf], target)
  if not visual then
    local p = api.nvim_win_get_cursor(0)
    mark(target, p[1] - 1, p[2], p[1] - 1, p[2], '')
    return target
  end
  local mode = vim.fn.mode():sub(1, 1)
  local a, b = vim.fn.getpos('v'), vim.fn.getpos('.')
  local opts = { type = mode, exclusive = vim.o.selection == 'exclusive', eol = true }
  local regions = vim.fn.getregionpos(a, b, opts)
  local selected = vim.fn.getregion(a, b, { type = mode, exclusive = opts.exclusive })
  target.block = mode == '\22'
  target.linewise = mode == 'V'
  if target.block then
    for i, pair in ipairs(regions) do
      local first, last = pair[1], pair[2]
      local row = first[2] - 1
      local value = line(buf, row)
      local sc, ec = math.min(#value, math.max(0, first[3] - 1)), math.min(#value, math.max(0, last[3] - 1))
      local prefix = string.rep(' ', first[4])
      local suffix = ''
      if ec < #value then
        while ec > 0 and value:byte(ec + 1) >= 128 and value:byte(ec + 1) < 192 do ec = ec - 1 end
        local stop = nextbyte(value, ec)
        if last[4] > 0 then
          local before = vim.fn.strdisplaywidth(value:sub(1, ec))
          local width = vim.fn.strdisplaywidth(value:sub(ec + 1, stop), before)
          suffix = string.rep(' ', math.max(0, width - last[4]))
        end
        ec = stop
      end
      mark(target, row, sc, row, ec, selected[i], prefix, suffix)
    end
  else
    local first, last = regions[1][1], regions[#regions][2]
    local sr, sc, er = first[2] - 1, math.max(0, first[3] - 1), last[2] - 1
    local ec = math.min(#line(buf, er), math.max(0, last[3]))
    if target.linewise then sc, ec = 0, #line(buf, er) end
    mark(target, sr, sc, er, ec, table.concat(selected, '\n'))
  end
  vim.cmd('normal! ' .. api.nvim_replace_termcodes('<Esc>', true, false, true))
  return target
end

function M.valid(target)
  if not target or target.invalid or not api.nvim_buf_is_valid(target.buf) or not api.nvim_buf_is_loaded(target.buf) then return false end
  for _, segment in ipairs(target.segments) do
    local p = position(target.buf, segment.mark)
    if not p or text_at(target.buf, p) ~= segment.expected then target.invalid = true; return false end
    segment.last = p
  end
  return true
end

function M.payload(target)
  if not M.valid(target) then return nil, 'The captured target changed; select it again' end
  local out = {}
  for _, segment in ipairs(target.segments) do
    local p = position(target.buf, segment.mark)
    out[#out + 1] = { id = segment.id, start = { p[1], p[2] }, ['end'] = { p[3], p[4] },
      text = segment.selected or segment.expected, coordinates = 'zero-based UTF-8 bytes; end-exclusive',
      before = line(target.buf, p[1]):sub(1, p[2]), after = line(target.buf, p[3]):sub(p[4] + 1) }
  end
  return out
end

function M.apply(target, replacements)
  if not M.valid(target) then return false, 'Target changed while Claude was working; result was not applied' end
  if not vim.bo[target.buf].modifiable then return false, 'Source buffer is not modifiable' end
  local by_id = {}
  for _, replacement in ipairs(replacements) do
    if by_id[replacement.id] or type(replacement.text) ~= 'string' then return false, 'Invalid replacement set' end
    by_id[replacement.id] = replacement.text
  end
  if #replacements ~= #target.segments then return false, 'Incomplete replacement set' end
  for _, segment in ipairs(target.segments) do
    if by_id[segment.id] == nil then return false, 'Missing target' end
    if target.block and by_id[segment.id]:find('[\r\n]') then return false, 'Block replacement contains a newline' end
  end
  local no_op = true
  for _, segment in ipairs(target.segments) do
    if segment.prefix .. by_id[segment.id] .. segment.suffix ~= segment.expected then no_op = false end
  end
  if no_op then return true, 'Completed without changing text' end
  applying = true
  local ok, err = pcall(api.nvim_buf_call, target.buf, function()
    -- Close the previous undo block without clearing history.
    vim.cmd('let &l:undolevels = &l:undolevels')
    for i = #target.segments, 1, -1 do
      local segment = target.segments[i]
      local p = position(target.buf, segment.mark)
      local replacement = segment.prefix .. by_id[segment.id] .. segment.suffix
      local lines = vim.split(replacement, '\n', { plain = true })
      if i < #target.segments then vim.cmd('undojoin') end
      api.nvim_buf_set_text(target.buf, p[1], p[2], p[3], p[4], lines)
      local sr, sc = p[1], p[2] + #segment.prefix
      local inserted = vim.split(by_id[segment.id], '\n', { plain = true })
      local er = sr + #inserted - 1
      local ec = #inserted == 1 and sc + #inserted[1] or #inserted[#inserted]
      api.nvim_buf_set_extmark(target.buf, ns, sr, sc, { id = segment.mark, end_row = er, end_col = ec,
        right_gravity = true, end_right_gravity = sr == er and sc == ec, hl_group = 'Visual', undo_restore = false })
      segment.expected, segment.selected = by_id[segment.id], nil
      segment.prefix, segment.suffix = '', ''
    end
  end)
  applying = false
  if not ok then target.invalid = true; return false, tostring(err) end
  for _, segment in ipairs(target.segments) do segment.last = position(target.buf, segment.mark) end
  return true, 'Applied ' .. #target.segments .. ' replacement(s)'
end

function M.dispose(target)
  if not target then return end
  if api.nvim_buf_is_valid(target.buf) then
    for _, segment in ipairs(target.segments) do pcall(api.nvim_buf_del_extmark, target.buf, ns, segment.mark) end
  end
  local list = targets[target.buf] or {}
  for i, value in ipairs(list) do if value == target then table.remove(list, i); break end end
end

return M
