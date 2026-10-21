local M = {}
local api = vim.api

local function restore(origin)
  if origin and api.nvim_win_is_valid(origin) then api.nvim_set_current_win(origin) end
end

local function config(title, height, centered)
  local width = math.max(1, math.min(72, vim.o.columns - 4))
  height = math.max(1, math.min(height, vim.o.lines - 4))
  local row, col = math.floor((vim.o.lines - height - 2) / 2), math.floor((vim.o.columns - width - 2) / 2)
  if not centered then
    local pos = vim.fn.screenpos(0, vim.fn.line('.'), vim.fn.col('.'))
    row = math.min(math.max(0, pos.row), vim.o.lines - height - 3)
    col = math.min(math.max(0, pos.col - 1), vim.o.columns - width - 2)
  end
  return { relative = 'editor', row = row, col = col, width = width, height = height,
    style = 'minimal', border = 'rounded', title = ' ' .. title .. ' ', title_pos = 'left' }
end

function M.result(title, origin)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].filetype = 'markdown'
  local win = api.nvim_open_win(buf, false, config(title, math.floor(vim.o.lines * .45), true))
  vim.wo[win].wrap = true
  local result = { buf = buf, win = win, origin = origin }
  function result.set(text)
    if api.nvim_buf_is_valid(buf) then
      api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, '\n', { plain = true }))
    end
  end
  function result.title(text)
    if api.nvim_win_is_valid(result.win) then api.nvim_win_set_config(result.win, { title = ' ' .. text .. ' ' }) end
  end
  function result.show()
    if not api.nvim_buf_is_valid(buf) then return end
    if not api.nvim_win_is_valid(result.win) then
      result.win = api.nvim_open_win(buf, true, config(title, math.floor(vim.o.lines * .45), true))
    else api.nvim_set_current_win(result.win) end
  end
  local function close()
    if api.nvim_win_is_valid(result.win) then api.nvim_win_close(result.win, true) end
    restore(origin)
  end
  for _, key in ipairs({ 'q', '<Esc>' }) do
    vim.keymap.set('n', key, close, { buffer = buf, silent = true })
  end
  return result
end

function M.prompt(operation, model, origin, submit, dismiss)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  local placement = config(operation .. ' · ' .. model, 3, false)
  local win = api.nvim_open_win(buf, true, placement)
  vim.wo[win].wrap = true
  local done = false
  local function close()
    if done then return end
    done = true
    if api.nvim_win_is_valid(win) then api.nvim_win_close(win, true) end
    restore(origin)
    dismiss()
  end
  local function send()
    local text = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
    if text == '' then return end
    if submit(text) then
      vim.cmd('stopinsert')
      close()
    end
  end
  vim.keymap.set({ 'i', 'n' }, '<C-s>', send, { buffer = buf, silent = true })
  vim.keymap.set('n', '<CR>', send, { buffer = buf, silent = true })
  vim.keymap.set('n', '<Esc>', close, { buffer = buf, silent = true })
  api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, { buffer = buf, callback = function()
    if api.nvim_win_is_valid(win) then
      local rows = api.nvim_buf_line_count(buf)
      local height = math.max(1, math.min(10, math.max(3, rows), vim.o.lines - 4))
      api.nvim_win_set_config(win, {
        relative = 'editor',
        height = height, row = math.max(0, math.min(placement.row, vim.o.lines - height - 3)),
        col = math.max(0, math.min(placement.col, vim.o.columns - placement.width - 2)),
      })
    end
  end })
  api.nvim_create_autocmd('BufWipeout', { buffer = buf, once = true, callback = function()
    if not done then done = true; restore(origin); dismiss() end
  end })
  vim.cmd('startinsert')
  return { buf = buf, win = win, close = close }
end

function M.system(text, save)
  vim.cmd('new')
  local buf = api.nvim_get_current_buf()
  api.nvim_buf_set_name(buf, 'nvim-claude://system/' .. buf)
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, '\n', { plain = true }))
  vim.bo[buf].modified = false
  api.nvim_create_autocmd('BufWriteCmd', { buffer = buf, callback = function()
    save(table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), '\n'), function(ok)
      if ok and api.nvim_buf_is_valid(buf) then vim.bo[buf].modified = false end
    end)
  end })
end

return M
