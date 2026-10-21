local M = {}
local api = vim.api

local function close(win, origin)
  if api.nvim_win_is_valid(win) then api.nvim_win_close(win, true) end
  if origin and api.nvim_win_is_valid(origin) then api.nvim_set_current_win(origin) end
end

local function geometry(center)
  local width = math.max(1, math.min(76, vim.o.columns - 4))
  local height = math.max(1, math.min(center and 18 or 4, vim.o.lines - 5))
  local config = { relative = 'editor', width = width, height = height, style = 'minimal', border = 'rounded' }
  if center then
    config.row, config.col = math.max(0, math.floor((vim.o.lines - height) / 2) - 1), math.max(0, math.floor((vim.o.columns - width) / 2))
  else
    local pos = vim.fn.screenpos(0, vim.fn.line('.'), vim.fn.col('.'))
    config.row = math.max(0, math.min(pos.row, vim.o.lines - height - 4))
    config.col = math.max(0, math.min(pos.col - 1, vim.o.columns - width - 2))
  end
  return config
end

function M.result(title, origin)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].filetype = 'markdown'
  local config = geometry(true)
  config.title = ' ' .. title .. ' '
  local win = api.nvim_open_win(buf, false, config)
  vim.wo[win].wrap = true
  local result = { buf = buf, win = win }
  for _, key in ipairs({ 'q', '<Esc>' }) do
    vim.keymap.set('n', key, function() close(win, origin) end, { buffer = buf, silent = true })
  end
  function result.update(text)
    if not api.nvim_buf_is_valid(buf) then return end
    vim.bo[buf].modifiable = true
    api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, '\n', { plain = true }))
    vim.bo[buf].modifiable = result.complete or false
  end
  function result.finish()
    result.complete = true
    if api.nvim_buf_is_valid(buf) then vim.bo[buf].modifiable = true end
  end
  function result.focus()
    if api.nvim_win_is_valid(win) then api.nvim_set_current_win(win)
    elseif api.nvim_buf_is_valid(buf) then win = api.nvim_open_win(buf, true, config); result.win = win end
  end
  function result.title(text)
    if api.nvim_win_is_valid(win) then api.nvim_win_set_config(win, { title = ' ' .. text .. ' ' }) end
  end
  return result
end

function M.prompt(title, origin, submit, dismiss)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'markdown'
  local config = geometry(false)
  config.title = ' ' .. title .. ' '
  config.footer = ' Ctrl-S submit · Esc normal, Esc close '
  local win = api.nvim_open_win(buf, true, config)
  vim.wo[win].wrap = true
  local function send()
    local instruction = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
    if not instruction:match('%S') then vim.notify('NvClaude: enter an instruction'); return end
    if submit(instruction) then
      vim.cmd.stopinsert()
      close(win, origin)
    end
  end
  vim.keymap.set({ 'i', 'n' }, '<C-s>', send, { buffer = buf, silent = true })
  vim.keymap.set('n', '<CR>', send, { buffer = buf, silent = true })
  vim.keymap.set('n', '<Esc>', function()
    close(win, origin)
    if dismiss then dismiss() end
  end, { buffer = buf, silent = true })
  api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, { buffer = buf, callback = function()
    if not api.nvim_win_is_valid(win) then return end
    local count = 0
    for _, text in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
      count = count + math.max(1, math.ceil(vim.fn.strdisplaywidth(text) / config.width))
    end
    local height = math.min(math.max(3, count), math.max(1, math.floor(vim.o.lines / 3)))
    api.nvim_win_set_config(win, { relative = 'editor', col = config.col, height = height,
      row = math.min(config.row, math.max(0, vim.o.lines - height - 4)) })
  end })
  vim.cmd.startinsert()
  return { buf = buf, win = win }
end

return M
