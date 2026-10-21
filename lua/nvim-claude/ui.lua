local M = {}
local function size(lines, minimum)
  local width = minimum or 48
  for _, line in ipairs(lines) do width = math.max(width, vim.fn.strdisplaywidth(line) + 2) end
  return math.min(width, math.max(1, vim.o.columns - 4)), math.min(math.max(3, #lines), math.max(1, math.floor(vim.o.lines * 0.45)))
end
function M.float(title, lines, origin, cursor, editable)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].filetype = editable and 'text' or 'markdown'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local width, height = size(lines)
  local cfg = { relative = 'editor', row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1), col = math.max(0, math.floor((vim.o.columns - width) / 2)), width = width, height = height, style = 'minimal', border = 'rounded', title = ' ' .. title .. ' ', title_pos = 'center' }
  if cursor and origin and vim.api.nvim_win_is_valid(origin) then
    local screen = vim.fn.screenpos(origin, cursor[1], cursor[2] + 1)
    cfg.row = math.min(math.max(0, screen.row), math.max(0, vim.o.lines - height - 3))
    cfg.col = math.min(math.max(0, screen.col - 1), math.max(0, vim.o.columns - width - 2))
  end
  local win = vim.api.nvim_open_win(buf, true, cfg)
  vim.wo[win].wrap = true
  local self = { buf = buf, win = win, origin = origin, config = cfg }
  function self.close()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    if origin and vim.api.nvim_win_is_valid(origin) then vim.api.nvim_set_current_win(origin) end
    if self.on_close then self.on_close() end
  end
  function self.title(value)
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_set_config(win, { title = ' ' .. value .. ' ' }) end
  end
  function self.set(value)
    if not vim.api.nvim_buf_is_valid(buf) then return end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(value, '\n', { plain = true }))
    if not editable then vim.bo[buf].modifiable = false end
  end
  vim.keymap.set('n', '<Esc>', self.close, { buffer = buf, silent = true })
  if not editable then
    vim.bo[buf].modifiable = false
    vim.keymap.set('n', 'q', self.close, { buffer = buf, silent = true })
  end
  return self
end
function M.prompt(title, origin, cursor, submit, close)
  local ui = M.float(title, { '' }, origin, cursor, true)
  ui.on_close = close
  local function run() submit(table.concat(vim.api.nvim_buf_get_lines(ui.buf, 0, -1, false), '\n'), ui) end
  vim.keymap.set({ 'n', 'i' }, '<C-s>', run, { buffer = ui.buf, silent = true })
  vim.keymap.set('n', '<CR>', run, { buffer = ui.buf, silent = true })
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, { buffer = ui.buf, callback = function()
    if not vim.api.nvim_win_is_valid(ui.win) then return end
    local width, height = size(vim.api.nvim_buf_get_lines(ui.buf, 0, -1, false))
    ui.config.width, ui.config.height = width, height
    ui.config.row = math.min(ui.config.row, math.max(0, vim.o.lines - height - 3))
    ui.config.col = math.min(ui.config.col, math.max(0, vim.o.columns - width - 2))
    vim.api.nvim_win_set_config(ui.win, ui.config)
  end })
  vim.cmd('startinsert')
  return ui
end
return M
