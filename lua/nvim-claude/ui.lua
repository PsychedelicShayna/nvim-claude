local M = {}
local a = vim.api
function M.float(title, text, origin, prompt)
  local b = a.nvim_create_buf(false, true)
  vim.bo[b].bufhidden = 'hide'
  local width = math.max(10, math.min(prompt and 62 or 88, vim.o.columns - 4))
  local height = math.min(prompt and 3 or 14, math.max(1, vim.o.lines - 5))
  local pos = vim.fn.screenpos(0, vim.fn.line('.'), vim.fn.col('.'))
  local row = prompt and math.min(pos.row, vim.o.lines - height - 4) or math.floor((vim.o.lines - height) / 2) - 1
  local col = prompt and math.min(math.max(0, pos.col - 1), vim.o.columns - width - 2) or math.floor((vim.o.columns - width) / 2)
  local w = a.nvim_open_win(b, true, { relative = 'editor', row = math.max(0, row), col = math.max(0, col),
    width = width, height = height, border = 'rounded', title = ' ' .. title .. ' ', style = 'minimal' })
  vim.wo[w].wrap = true
  local obj = { buf = b, win = w, origin = origin }
  function obj.set(value)
    if a.nvim_buf_is_valid(b) then
      vim.bo[b].modifiable = true
      a.nvim_buf_set_lines(b, 0, -1, false, vim.split(value, '\n', { plain = true }))
      vim.bo[b].modifiable = prompt or false
    end
  end
  function obj.close()
    if a.nvim_win_is_valid(w) then a.nvim_win_close(w, true) end
    if origin and a.nvim_win_is_valid(origin) then a.nvim_set_current_win(origin) end
  end
  obj.set(text or '')
  vim.keymap.set('n', '<Esc>', obj.close, { buffer = b })
  if not prompt then
    vim.bo[b].filetype = 'markdown'
    vim.keymap.set('n', 'q', obj.close, { buffer = b })
  else
    a.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, { buffer = b, callback = function()
      if a.nvim_win_is_valid(w) then
        local h = math.min(math.max(3, a.nvim_buf_line_count(b)), math.max(1, math.floor(vim.o.lines / 3)))
        a.nvim_win_set_config(w, { height = h, row = math.min(math.max(0, row), math.max(0, vim.o.lines - h - 4)) })
      end
    end })
  end
  return obj
end
function M.prompt(title, origin, submit)
  local p = M.float(title, '', origin, true)
  local function send()
    local instruction = table.concat(a.nvim_buf_get_lines(p.buf, 0, -1, false), '\n')
    if instruction == '' then return end
    if submit(instruction) then vim.cmd('stopinsert'); p.close() end
  end
  vim.keymap.set({ 'i', 'n' }, '<C-s>', send, { buffer = p.buf })
  vim.keymap.set('n', '<CR>', send, { buffer = p.buf })
  vim.cmd('startinsert')
  return p
end
return M
