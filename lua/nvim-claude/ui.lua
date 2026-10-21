local M = {}
local api = vim.api

local function focus(origin)
  if origin and api.nvim_win_is_valid(origin) then api.nvim_set_current_win(origin) end
end

function M.result(title, text, origin, enter)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].filetype = 'nofile', 'hide', 'markdown'
  local width = math.max(1, math.min(90, vim.o.columns - 4))
  local height = math.max(1, math.min(22, vim.o.lines - 5))
  local win = api.nvim_open_win(buf, enter ~= false, { relative = 'editor',
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)), width = width, height = height,
    style = 'minimal', border = 'rounded', title = ' ' .. title .. ' ', title_pos = 'center' })
  vim.wo[win].wrap = true
  local view = { buf = buf, win = win, origin = origin }
  function view.update(value)
    if not api.nvim_buf_is_valid(buf) then return end
    vim.bo[buf].modifiable = true
    api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(value, '\n', { plain = true }))
  end
  function view.close()
    if api.nvim_win_is_valid(win) then api.nvim_win_close(win, true) end
    focus(origin)
  end
  for _, key in ipairs({ 'q', '<Esc>' }) do vim.keymap.set('n', key, view.close, { buffer = buf, silent = true }) end
  view.update(text or '')
  return view
end

function M.prompt(title, origin, submit, dismiss)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].filetype = 'nofile', 'wipe', 'text'
  local cursor = api.nvim_win_get_cursor(origin)
  local pos = vim.fn.screenpos(origin, cursor[1], cursor[2] + 1)
  local width = math.max(1, math.min(64, vim.o.columns - 4))
  local row = math.max(0, math.min((pos.row or 1), vim.o.lines - 7))
  local col = math.max(0, math.min((pos.col or 1) - 1, vim.o.columns - width - 2))
  local win = api.nvim_open_win(buf, true, { relative = 'editor', row = row, col = col,
    width = width, height = math.min(3, math.max(1, vim.o.lines - 4)), style = 'minimal',
    border = 'rounded', title = ' ' .. title .. ' ', footer = ' Ctrl-S send · Esc normal/close ', footer_pos = 'right' })
  vim.wo[win].wrap = true
  local closed = false
  local function close(cancel)
    if closed then return end
    closed = true
    vim.cmd('stopinsert')
    if api.nvim_win_is_valid(win) then api.nvim_win_close(win, true) end
    focus(origin)
    if cancel and dismiss then dismiss() end
  end
  local function send()
    local text = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
    if submit(text, function() close(false) end) then close(false) end
  end
  vim.keymap.set({ 'i', 'n' }, '<C-s>', send, { buffer = buf, silent = true })
  vim.keymap.set('n', '<CR>', send, { buffer = buf, silent = true })
  vim.keymap.set('n', '<Esc>', function() close(true) end, { buffer = buf, silent = true })
  api.nvim_create_autocmd({ 'TextChangedI', 'TextChanged' }, { buffer = buf, callback = function()
    if not api.nvim_win_is_valid(win) then return end
    local rows = 0
    for _, text in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do rows = rows + math.max(1, math.ceil(vim.fn.strdisplaywidth(text) / width)) end
    local height = math.max(3, math.min(10, rows + 1, vim.o.lines - 5))
    local conf = api.nvim_win_get_config(win)
    conf.height, conf.row = height, math.min(row, math.max(0, vim.o.lines - height - 3))
    api.nvim_win_set_config(win, conf)
  end })
  api.nvim_create_autocmd('BufWipeout', { buffer = buf, once = true, callback = function()
    if not closed and dismiss then dismiss() end
  end })
  vim.cmd('startinsert')
  return { buf = buf, win = win, close = close }
end

return M
