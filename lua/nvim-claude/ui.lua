local M = {}
local ns = vim.api.nvim_create_namespace('nvim-claude-ui')
local prompt, answer

local function fit(width, height, origin)
  local w = math.min(math.max(24, width), math.max(1, vim.o.columns - 4))
  local h = math.min(math.max(1, height), math.max(1, vim.o.lines - 4))
  local win = vim.api.nvim_win_is_valid(origin) and origin or vim.api.nvim_get_current_win()
  local pos = vim.api.nvim_win_get_position(win)
  local cursor = vim.api.nvim_win_get_cursor(win)
  local screen = vim.api.nvim_win_call(win, function()
    return { vim.fn.line('w0'), vim.fn.wincol() }
  end)
  local row = pos[1] + cursor[1] - screen[1] + 1
  local col = pos[2] + screen[2] - 1
  return { relative = 'editor', style = 'minimal', border = 'rounded',
    row = math.min(math.max(0, row), math.max(0, vim.o.lines - h - 3)),
    col = math.min(math.max(0, col), math.max(0, vim.o.columns - w - 2)),
    width = w, height = h }
end
local function restore(origin)
  if origin and vim.api.nvim_win_is_valid(origin) then vim.api.nvim_set_current_win(origin) end
end
local function close(view)
  if view and view.win and vim.api.nvim_win_is_valid(view.win) then
    vim.api.nvim_win_close(view.win, true)
  end
  if view then view.win = nil end
  if view then restore(view.origin) end
end
function M.prompt(opts)
  if prompt then close(prompt) end
  local origin = opts.origin or vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'; vim.bo[buf].bufhidden = 'wipe'; vim.bo[buf].filetype = 'markdown'
  local config = fit(58, 3, origin)
  config.title = (' %s · %s '):format(opts.operation, opts.model)
  config.title_pos = 'center'
  local win = vim.api.nvim_open_win(buf, true, config)
  vim.wo[win].wrap = true
  prompt = { buf = buf, win = win, origin = origin, on_submit = opts.submit, on_close = opts.dismiss }
  local this = prompt
  local function dismiss()
    if prompt ~= this then return end
    prompt = nil; close(this)
    if this.on_close then this.on_close() end
  end
  local function submit()
    if prompt ~= this then return end
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
    if vim.trim(text) == '' then vim.notify('nvim-claude: Enter an instruction', vim.log.levels.WARN); return end
    if this.on_submit(text) == false then return end
    prompt = nil; close(this)
  end
  for _, mode in ipairs({ 'n', 'i' }) do
    vim.keymap.set(mode, '<C-s>', submit, { buffer = buf, nowait = true, silent = true })
  end
  vim.keymap.set('n', '<CR>', submit, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set('n', '<Esc>', dismiss, { buffer = buf, nowait = true, silent = true })
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    buffer = buf, callback = function()
      if prompt ~= this or not vim.api.nvim_win_is_valid(win) then return end
      local height = math.min(12, math.max(3, vim.api.nvim_buf_line_count(buf) + 1))
      local cfg = vim.api.nvim_win_get_config(win); cfg.height = height
      cfg.row = math.min(tonumber(cfg.row) or 0, vim.o.lines - height - 3)
      vim.api.nvim_win_set_config(win, cfg)
    end,
  })
  vim.cmd.startinsert()
end

function M.answer(opts)
  local view = { origin = opts.origin, title = opts.title, text = '', status = opts.status or 'waiting' }
  answer = view
  M.show(view)
  return view
end
function M.show(view)
  if view.win and vim.api.nvim_win_is_valid(view.win) then return end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'; vim.bo[buf].bufhidden = 'wipe'; vim.bo[buf].filetype = 'markdown'
  local cfg = fit(math.min(84, math.floor(vim.o.columns * 0.75)), math.min(14, math.floor(vim.o.lines * 0.5)), view.origin)
  cfg.title = ' ' .. (view.title or 'Claude answer') .. ' · ' .. view.status .. ' '
  cfg.title_pos = 'center'
  view.buf = buf; view.win = vim.api.nvim_open_win(buf, true, cfg)
  vim.wo[view.win].wrap = true
  vim.keymap.set('n', 'q', function() close(view) end, { buffer = buf, silent = true })
  vim.keymap.set('n', '<Esc>', function() close(view) end, { buffer = buf, silent = true })
  M.update(view, view.text, view.status)
end
function M.update(view, text, status)
  view.text = text or view.text
  view.status = status or view.status
  if not view.win or not vim.api.nvim_win_is_valid(view.win) then return end
  local lines = vim.split(view.text, '\n', { plain = true })
  vim.bo[view.buf].modifiable = true
  vim.api.nvim_buf_set_lines(view.buf, 0, -1, false, lines)
  vim.bo[view.buf].modifiable = view.status == 'complete' or view.status == 'ready' or
    view.status == 'not applied' or view.status == 'needs input' or view.status == 'failed'
  local cfg = vim.api.nvim_win_get_config(view.win)
  cfg.title = ' ' .. (view.title or 'Claude answer') .. ' · ' .. view.status .. ' '
  vim.api.nvim_win_set_config(view.win, cfg)
  vim.api.nvim_buf_clear_namespace(view.buf, ns, 0, -1)
end
function M.last_answer() return answer end
function M.message(title, lines, origin)
  local view = M.answer({ title = title, origin = origin, status = 'ready' })
  M.update(view, type(lines) == 'table' and table.concat(lines, '\n') or tostring(lines), 'ready')
  return view
end
return M
