local M = {}
local api = vim.api
local ns = api.nvim_create_namespace('nvim-claude-targets')
local serial = 0

local function line(buf, row)
  return api.nvim_buf_get_lines(buf, row, row + 1, true)[1] or ''
end
local function char_end(text, col)
  if col >= #text then return #text end
  local nextcol = col + 1
  while nextcol < #text do
    local b = text:byte(nextcol + 1)
    if b < 128 or b >= 192 then break end
    nextcol = nextcol + 1
  end
  return nextcol
end
local function text_at(buf, s, e)
  return table.concat(api.nvim_buf_get_text(buf, s[1], s[2], e[1], e[2], {}), '\n')
end
local function mark(buf, s, e, extra)
  serial = serial + 1
  local item = {id = 'target-' .. serial, prefix = '', suffix = ''}
  for k, v in pairs(extra or {}) do item[k] = v end
  item.mark = api.nvim_buf_set_extmark(buf, ns, s[1], s[2], {
    end_row = e[1], end_col = e[2], right_gravity = false, end_right_gravity = true,
    hl_group = 'Visual', undo_restore = false, invalidate = true,
  })
  item.original = text_at(buf, s, e)
  item.text = item.text or item.original
  return item
end

function M.positions(target, item)
  if not api.nvim_buf_is_valid(target.buf) or not api.nvim_buf_is_loaded(target.buf) then
    return nil, 'Source buffer no longer exists'
  end
  local pos = api.nvim_buf_get_extmark_by_id(target.buf, ns, item.mark, {details = true})
  if #pos == 0 or pos[3].invalid then return nil, 'Target was deleted or undone' end
  return {pos[1], pos[2]}, {pos[3].end_row, pos[3].end_col}
end

function M.valid(target)
  if not target then return false, 'Select a target first' end
  for _, item in ipairs(target.items) do
    local s, e = M.positions(target, item)
    if not s then return false, e end
    if text_at(target.buf, s, e) ~= item.original then return false, 'Target changed while the request was running' end
    if item.boundary then
      local text = line(target.buf, s[1])
      if text:sub(math.max(1, s[2] - 31), s[2]) ~= item.boundary[1]
          or text:sub(s[2] + 1, s[2] + 32) ~= item.boundary[2] then
        return false, 'Insertion boundary changed'
      end
    end
  end
  return true
end

function M.capture(operation, visual)
  local buf, win = api.nvim_get_current_buf(), api.nvim_get_current_win()
  local target = {buf = buf, win = win, items = {}, block = false}
  if not visual then
    local cursor = api.nvim_win_get_cursor(win)
    local s = {cursor[1] - 1, cursor[2]}
    local text = line(buf, s[1])
    target.items[1] = mark(buf, s, s, {boundary = {
      text:sub(math.max(1, s[2] - 31), s[2]), text:sub(s[2] + 1, s[2] + 32)}})
    return target
  end
  local mode = vim.fn.mode()
  local a, b = vim.fn.getpos('v'), vim.fn.getpos('.')
  local opts = {type = mode, exclusive = vim.o.selection == 'exclusive', eol = true}
  local regions = vim.fn.getregionpos(a, b, opts)
  local selected = vim.fn.getregion(a, b, {type = mode, exclusive = opts.exclusive})
  if #regions == 0 then error('Selection is empty') end
  target.block = mode:sub(1, 1) == '\22'
  if target.block then
    for i, region in ipairs(regions) do
      local left, right = region[1], region[2]
      local row = left[2] - 1
      local text = line(buf, row)
      local sc = math.max(0, math.min(#text, left[3] - 1))
      local ec = math.max(sc, math.min(#text, right[3] - 1))
      local prefix, suffix = string.rep(' ', left[4]), ''
      if ec < #text then
        local ending = char_end(text, ec)
        if right[4] > 0 then
          local width = vim.fn.strdisplaywidth(text:sub(ec + 1, ending), vim.fn.strdisplaywidth(text:sub(1, ec)))
          suffix = string.rep(' ', math.max(0, width - right[4]))
        end
        ec = ending
      end
      target.items[#target.items + 1] = mark(buf, {row, sc}, {row, ec}, {
        prefix = prefix, suffix = suffix, text = selected[i] or '',
      })
    end
  else
    local first, last = regions[1][1], regions[#regions][2]
    local s = {first[2] - 1, math.max(0, first[3] - 1)}
    local e = {last[2] - 1, char_end(line(buf, last[2] - 1), math.max(0, last[3] - 1))}
    if mode == 'V' then
      s[2] = 0
      e[2] = #line(buf, e[1])
      -- Preserve linewise semantics, including the separating newline where present.
      if e[1] + 1 < api.nvim_buf_line_count(buf) then e = {e[1] + 1, 0} end
    end
    target.items[1] = mark(buf, s, e)
  end
  api.nvim_feedkeys(api.nvim_replace_termcodes('<Esc>', true, false, true), 'nx', false)
  return target
end

function M.dispatch(target)
  local valid, reason = M.valid(target)
  if not valid then error(reason) end
  local result = {}
  for _, item in ipairs(target.items) do
    local s, e = M.positions(target, item)
    result[#result + 1] = {id = item.id, start = s, ['end'] = e, text = item.text,
      coordinates = 'zero-based UTF-8 bytes; end-exclusive',
      before = line(target.buf, s[1]):sub(math.max(1, s[2] - 31), s[2]),
      after = line(target.buf, e[1]):sub(e[2] + 1, e[2] + 32)}
  end
  return result
end

function M.clear(target)
  if target and api.nvim_buf_is_valid(target.buf) then
    for _, item in ipairs(target.items) do pcall(api.nvim_buf_del_extmark, target.buf, ns, item.mark) end
  end
end

function M.apply(target, replacements)
  local valid, reason = M.valid(target)
  if not valid then return false, reason end
  if not vim.bo[target.buf].modifiable or vim.bo[target.buf].readonly then return false, 'Source is not writable' end
  local by_id = {}
  for _, item in ipairs(replacements) do
    if by_id[item.id] or type(item.text) ~= 'string' then return false, 'Invalid replacement IDs' end
    if target.block and item.text:find('\n', 1, true) then return false, 'Block result contains a newline' end
    by_id[item.id] = item.text
  end
  if #replacements ~= #target.items then return false, 'Wrong number of replacements' end
  for _, item in ipairs(target.items) do if by_id[item.id] == nil then return false, 'Missing replacement' end end
  local updated = {}
  api.nvim_buf_call(target.buf, function()
    -- Closing the previous undo block does not discard history or join user typing.
    vim.cmd('let &undolevels = &undolevels')
    for i = #target.items, 1, -1 do
      local item = target.items[i]
      local s, e = M.positions(target, item)
      local replacement = item.prefix .. by_id[item.id] .. item.suffix
      if i < #target.items then vim.cmd('undojoin') end
      api.nvim_buf_set_text(target.buf, s[1], s[2], e[1], e[2], vim.split(replacement, '\n', {plain = true}))
      api.nvim_buf_del_extmark(target.buf, ns, item.mark)
      local lines = vim.split(by_id[item.id], '\n', {plain = true})
      local start = {s[1], s[2] + #item.prefix}
      local finish = {start[1] + #lines - 1, #lines == 1 and start[2] + #lines[1] or #lines[#lines]}
      updated[i] = mark(target.buf, start, finish)
    end
  end)
  target.items = updated
  return true
end

return M
