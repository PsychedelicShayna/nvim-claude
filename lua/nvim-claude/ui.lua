local M = {}
local active = {}
local function geometry(width, height, win)
  local maxw = math.max(20, vim.o.columns - 4)
  local maxh = math.max(3, vim.o.lines - 5)
  width, height = math.min(width, maxw), math.min(height, maxh)
  local row, col = 1, math.max(0, math.floor((vim.o.columns - width) / 2))
  if win and vim.api.nvim_win_is_valid(win) then
    local cursor = vim.api.nvim_win_get_position(win)
    local pos = vim.api.nvim_win_get_cursor(win)
    row = math.max(0, math.min(maxh - height, cursor[1] + pos[1]))
    col = math.max(0, math.min(vim.o.columns - width - 2, cursor[2] + pos[2] + 3))
  end
  return { relative = 'editor', row = row, col = col, width = width, height = height,
    style = 'minimal', border = 'rounded' }
end
local function close(item)
  if item.win and vim.api.nvim_win_is_valid(item.win) then vim.api.nvim_win_close(item.win, true) end
  if item.origin and vim.api.nvim_win_is_valid(item.origin) then vim.api.nvim_set_current_win(item.origin) end
end

function M.prompt(capture, model, submit)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].filetype = 'markdown'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '' })
  local item = { origin = capture.win }
  item.win = vim.api.nvim_open_win(buf, true, vim.tbl_extend('force', geometry(56, 5, capture.win), {
    title = ' ' .. capture.operation .. ' · ' .. model .. ' (Ctrl-S to send) ', title_pos = 'center',
  }))
  active[item.win] = item
  local function send()
    if not vim.api.nvim_buf_is_valid(buf) then return end
    local input = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
    if input:match('^%s*$') then return end
    submit(input, function() close(item) end)
  end
  local function dismiss() close(item) end
  for _, mode in ipairs({ 'n', 'i' }) do
    vim.keymap.set(mode, '<C-s>', send, { buffer = buf, nowait = true })
  end
  vim.keymap.set('n', '<CR>', send, { buffer = buf, nowait = true })
  vim.keymap.set('n', '<Esc>', dismiss, { buffer = buf, nowait = true })
  vim.api.nvim_create_autocmd('TextChangedI', { buffer = buf, callback = function()
    if not vim.api.nvim_win_is_valid(item.win) then return end
    local count = vim.api.nvim_buf_line_count(buf)
    vim.api.nvim_win_set_config(item.win, vim.tbl_extend('force', geometry(56, math.min(12, math.max(5, count + 2)), capture.win), {
      title = ' ' .. capture.operation .. ' · ' .. model .. ' (Ctrl-S to send) ', title_pos = 'center',
    }))
  end })
  vim.cmd.startinsert()
end

function M.answer(title, origin)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].filetype = 'markdown'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '' })
  local item = { origin = origin, buf = buf, text = '' }
  item.win = vim.api.nvim_open_win(buf, true, vim.tbl_extend('force', geometry(76, 15, origin), {
    title = ' ' .. title .. ' ', title_pos = 'center',
  }))
  local function dismiss() close(item) end
  vim.keymap.set('n', 'q', dismiss, { buffer = buf, nowait = true })
  vim.keymap.set('n', '<Esc>', dismiss, { buffer = buf, nowait = true })
  return function(text)
    item.text = text
    if not vim.api.nvim_buf_is_valid(buf) then return end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, '\n', { plain = true }))
    vim.bo[buf].modifiable = false
  end
end

function M.message(title, text, origin)
  M.answer(title, origin)(text)
end
return M
