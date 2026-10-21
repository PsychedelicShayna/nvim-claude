local M = {}
local api = vim.api

function M.restore(win)
  if win and api.nvim_win_is_valid(win) then api.nvim_set_current_win(win) end
end
local function geometry(height, center, origin)
  local width = math.max(1, math.min(72, vim.o.columns - 4))
  height = math.max(1, math.min(height, vim.o.lines - 5))
  local row, col = math.floor((vim.o.lines - height) / 2) - 1, math.floor((vim.o.columns - width) / 2)
  if not center and origin and api.nvim_win_is_valid(origin) then
    local cursor = api.nvim_win_get_cursor(origin)
    local pos = vim.fn.screenpos(origin, cursor[1], cursor[2] + 1)
    row = pos.row
    if row + height + 2 >= vim.o.lines - 1 then row = math.max(0, pos.row - height - 2) end
    col = math.max(0, math.min(vim.o.columns - width - 2, pos.col - 1))
  end
  return { relative = 'editor', row = math.max(0, row), col = math.max(0, col),
    width = width, height = height, style = 'minimal', border = 'rounded', zindex = 60 }
end

function M.result(title, origin, center)
  local view = { buf = api.nvim_create_buf(false, true), origin = origin, text = '', hidden = false }
  vim.bo[view.buf].bufhidden = 'hide'
  vim.bo[view.buf].filetype = 'markdown'
  local config = geometry(center and 16 or 8, center, origin)
  config.title = ' ' .. title .. ' '
  config.title_pos = 'center'
  view.win = api.nvim_open_win(view.buf, false, config)
  vim.wo[view.win].wrap = true
  vim.wo[view.win].conceallevel = 0
  function view.close()
    view.hidden = true
    if api.nvim_win_is_valid(view.win) then api.nvim_win_close(view.win, true) end
    M.restore(origin)
  end
  for _, key in ipairs({ 'q', '<Esc>' }) do
    vim.keymap.set('n', key, view.close, { buffer = view.buf, silent = true, nowait = true })
  end
  function view.set(text)
    view.text = text
    if api.nvim_buf_is_valid(view.buf) then
      api.nvim_buf_set_lines(view.buf, 0, -1, false, vim.split(text, '\n', { plain = true }))
    end
  end
  function view.append(text) view.set(view.text .. text) end
  function view.status(status)
    if api.nvim_win_is_valid(view.win) then
      api.nvim_win_set_config(view.win, { title = ' ' .. title .. ' · ' .. status .. ' ' })
    end
  end
  function view.show()
    if not api.nvim_buf_is_valid(view.buf) then return end
    if not api.nvim_win_is_valid(view.win) then
      view.win = api.nvim_open_win(view.buf, true, config)
    else api.nvim_set_current_win(view.win) end
    view.hidden = false
  end
  return view
end

function M.prompt(operation, model, origin, submit, dismiss)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'markdown'
  local config = geometry(3, false, origin)
  config.title = ' ' .. operation .. ' · ' .. model .. ' '
  config.title_pos = 'center'
  config.footer = ' Ctrl-S send · Esc Esc close '
  config.footer_pos = 'right'
  local win = api.nvim_open_win(buf, true, config)
  vim.wo[win].wrap = true
  local closed = false
  local function close(sent)
    if closed then return end
    closed = true
    vim.cmd('stopinsert')
    if api.nvim_win_is_valid(win) then api.nvim_win_close(win, true) end
    M.restore(origin)
    if not sent and dismiss then dismiss() end
  end
  local function send()
    local instruction = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
    if instruction:match('^%s*$') then return end
    if submit(instruction) then close(true) end
  end
  vim.keymap.set({ 'n', 'i' }, '<C-s>', send, { buffer = buf, silent = true })
  vim.keymap.set('n', '<CR>', send, { buffer = buf, silent = true })
  vim.keymap.set('n', '<Esc>', function() close(false) end, { buffer = buf, silent = true, nowait = true })
  api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, { buffer = buf, callback = function()
    if not api.nvim_win_is_valid(win) then return end
    local height = math.min(10, math.max(3, api.nvim_buf_line_count(buf)))
    local next_config = geometry(height, false, origin)
    api.nvim_win_set_config(win, { height = next_config.height, row = next_config.row, col = next_config.col })
  end })
  api.nvim_create_autocmd('BufWipeout', { buffer = buf, once = true, callback = function()
    if not closed then closed = true; if dismiss then dismiss() end end
  end })
  vim.cmd('startinsert')
  return { buf = buf, win = win, close = close }
end

return M
