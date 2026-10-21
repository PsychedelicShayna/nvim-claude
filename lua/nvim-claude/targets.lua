local M = {}
local api = vim.api
local ns = api.nvim_create_namespace('nvim-claude-targets')
local attached, targets = {}, {}
local serial = 0
local applying = false

local function char_end(line, col)
  if col >= #line then return #line end
  local next_col = col + 1
  while next_col < #line do
    local b = line:byte(next_col + 1)
    if b < 128 or b >= 192 then break end
    next_col = next_col + 1
  end
  return next_col
end

local function position(t)
  if not api.nvim_buf_is_valid(t.buf) then return nil end
  local p = api.nvim_buf_get_extmark_by_id(t.buf, ns, t.mark, { details = true })
  if #p == 0 or p[3].invalid then return nil end
  return { p[1], p[2], p[3].end_row, p[3].end_col }
end

local function text_at(buf, p)
  return table.concat(api.nvim_buf_get_text(buf, p[1], p[2], p[3], p[4], {}), '\n')
end

local function before(r, c, r2, c2)
  return r < r2 or (r == r2 and c < c2)
end

local function attach(buf)
  if attached[buf] then return end
  attached[buf] = true
  api.nvim_buf_attach(buf, false, {
    on_bytes = function(_, b, _, row, col, _, old_rows, old_col)
      if applying then return end
      local er, ec = row + old_rows, old_rows == 0 and col + old_col or old_col
      for _, target in pairs(targets) do
        if target.buf == b and not target.invalid then
          local p = position(target)
          if not p then target.invalid = true
          else
            local insertion = row == er and col == ec
            local empty = p[1] == p[3] and p[2] == p[4]
            local overlaps = before(row, col, p[3], p[4]) and before(p[1], p[2], er, ec)
            if insertion then
              overlaps = before(p[1], p[2], row, col) and before(row, col, p[3], p[4])
            end
            if empty then
              overlaps = not before(p[1], p[2], row, col) and not before(er, ec, p[1], p[2])
            end
            if overlaps then target.invalid = true end
          end
        end
      end
    end,
    on_detach = function(_, b)
      attached[b] = nil
      for _, target in pairs(targets) do if target.buf == b then target.invalid = true end end
    end,
  })
end

local function target(buf, sr, sc, er, ec, selected, prefix, suffix)
  serial = serial + 1
  local t = { id = 'target-' .. serial, buf = buf, prefix = prefix or '', suffix = suffix or '', text = selected }
  t.mark = api.nvim_buf_set_extmark(buf, ns, sr, sc, {
    end_row = er, end_col = ec, right_gravity = false, end_right_gravity = true,
    hl_group = 'Visual', undo_restore = false, invalidate = true,
  })
  t.original = text_at(buf, { sr, sc, er, ec })
  targets[t.id] = t
  attach(buf)
  return t
end

function M.capture(buf, mode)
  local a, b = vim.fn.getpos('v'), vim.fn.getpos('.')
  a[1], b[1] = buf, buf
  local opts = { type = mode, exclusive = vim.o.selection == 'exclusive', eol = true }
  local regions = vim.fn.getregionpos(a, b, opts)
  local texts = vim.fn.getregion(a, b, opts)
  local set = { buf = buf, block = mode:sub(1, 1) == '\22', items = {} }
  if #regions == 0 then return nil, 'Selection is empty' end
  if not set.block then
    local start, finish = regions[1][1], regions[#regions][2]
    local sr, sc, er = start[2] - 1, math.max(0, start[3] - 1), finish[2] - 1
    local line = api.nvim_buf_get_lines(buf, er, er + 1, false)[1]
    local ec = char_end(line, math.max(0, finish[3] - 1))
    if mode == 'V' then sc, ec = 0, #line end
    set.items[1] = target(buf, sr, sc, er, ec, table.concat(texts, '\n'))
  else
    for i, region in ipairs(regions) do
      local start, finish = region[1], region[2]
      local row = start[2] - 1
      local line = api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
      local sc = math.min(#line, math.max(0, start[3] - 1))
      local last = math.min(#line, math.max(0, finish[3] - 1))
      local ec = char_end(line, last)
      local prefix, suffix = string.rep(' ', start[4]), ''
      if finish[4] > 0 and last < #line then
        local width = vim.fn.strdisplaywidth(line:sub(last + 1, ec), vim.fn.strdisplaywidth(line:sub(1, last)))
        suffix = string.rep(' ', math.max(0, width - finish[4]))
      end
      set.items[#set.items + 1] = target(buf, row, sc, row, ec, texts[i], prefix, suffix)
    end
  end
  return set
end

function M.insertion(buf)
  local cursor = api.nvim_win_get_cursor(0)
  local row, col = cursor[1] - 1, cursor[2]
  return { buf = buf, items = { target(buf, row, col, row, col, '') } }
end

function M.valid(set)
  if not set or not api.nvim_buf_is_valid(set.buf) or not api.nvim_buf_is_loaded(set.buf) then return false end
  for _, t in ipairs(set.items) do
    local p = position(t)
    if t.invalid or not p or text_at(t.buf, p) ~= t.original then return false end
  end
  return true
end

function M.snapshot(set)
  if not M.valid(set) then return nil, 'Target changed or no longer exists; select it again' end
  local result = {}
  for _, t in ipairs(set.items) do
    local p = position(t)
    local before_line = api.nvim_buf_get_lines(t.buf, p[1], p[1] + 1, false)[1]
    local after_line = api.nvim_buf_get_lines(t.buf, p[3], p[3] + 1, false)[1]
    local prefix = before_line:sub(1, p[2])
    result[#result + 1] = { id = t.id, start = { p[1], p[2] }, ['end'] = { p[3], p[4] },
      text = t.text, coordinates = 'zero-based UTF-8 bytes; end-exclusive',
      before = vim.fn.strcharpart(prefix, math.max(0, vim.fn.strchars(prefix) - 40)),
      after = vim.fn.strcharpart(after_line:sub(p[4] + 1), 0, 40) }
  end
  return result
end

function M.highlight(set, enabled)
  if not set or not api.nvim_buf_is_valid(set.buf) then return end
  for _, t in ipairs(set.items) do
    local p = position(t)
    if p then
      api.nvim_buf_set_extmark(t.buf, ns, p[1], p[2], { id = t.mark, end_row = p[3], end_col = p[4],
        right_gravity = false, end_right_gravity = true, hl_group = enabled and 'Visual' or '',
        undo_restore = false, invalidate = true })
    end
  end
end

function M.apply(set, replacements)
  if not M.valid(set) then return nil, 'Target changed while Claude was working; result retained' end
  if not vim.bo[set.buf].modifiable then return nil, 'Source buffer is not modifiable; result retained' end
  local by_id = {}
  for _, r in ipairs(replacements) do
    if by_id[r.id] or type(r.text) ~= 'string' then return nil, 'Invalid replacement envelope' end
    by_id[r.id] = r.text
  end
  if #replacements ~= #set.items then return nil, 'Replacement count differs from target count' end
  for _, t in ipairs(set.items) do
    if not by_id[t.id] or (set.block and by_id[t.id]:find('[\r\n]')) then return nil, 'Invalid target replacement' end
  end
  local next_set = { buf = set.buf, block = set.block, items = {} }
  applying = true
  local ok, err = pcall(api.nvim_buf_call, set.buf, function()
    -- Closing the current undo block prevents joining the user's prior typing.
    local undo = vim.bo[set.buf].undolevels
    vim.bo[set.buf].undolevels = undo
    for i = #set.items, 1, -1 do
      local t = set.items[i]
      local p = position(t)
      local value = t.prefix .. by_id[t.id] .. t.suffix
      local lines = vim.split(value, '\n', { plain = true })
      if i < #set.items then vim.cmd('undojoin') end
      api.nvim_buf_set_text(set.buf, p[1], p[2], p[3], p[4], lines)
      local end_row = p[1] + #lines - 1
      local end_col = #lines == 1 and p[2] + #lines[1] or #lines[#lines]
      local start_col = p[2] + #t.prefix
      local new = target(set.buf, p[1], start_col, end_row, end_col - #t.suffix, by_id[t.id])
      table.insert(next_set.items, 1, new)
      t.invalid = true
      api.nvim_buf_del_extmark(set.buf, ns, t.mark)
      targets[t.id] = nil
    end
  end)
  applying = false
  if not ok then return nil, tostring(err) end
  M.highlight(next_set, false)
  return next_set
end

function M.release(set)
  if not set then return end
  for _, t in ipairs(set.items) do
    if api.nvim_buf_is_valid(t.buf) then pcall(api.nvim_buf_del_extmark, t.buf, ns, t.mark) end
    targets[t.id] = nil
  end
end

return M
