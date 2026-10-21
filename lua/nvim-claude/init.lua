local bridge = require('nvim-claude.bridge')
local targets = require('nvim-claude.targets')
local M = {}
local active, prompt_window, answer_window, last_result
local model = 'claude-haiku-5-5'
local punctuation = 'allow'
local configured = false
local owned_maps = {}
local generation = 0

local defaults = {
  replace = '<leader>cc', replace_short = '<leader>c', ask = '<leader>ca',
  generate = '<leader>ci', generate_insert = false, model = '<leader>cm',
  model_manual = '<leader>cM', clear = '<leader>cC', new = '<leader>cn',
  sticky = '<leader>cS', save = '<leader>cs', info = '<leader>cx', list = '<leader>cl',
}
local modes = {
  replace = { 'n', 'x' }, replace_short = { 'n', 'x' }, ask = { 'n', 'x' },
  generate = { 'n' }, generate_insert = { 'i' }, model = { 'n' },
  model_manual = { 'n' }, clear = { 'n' }, new = { 'n' }, sticky = { 'n' },
  save = { 'n' }, info = { 'n' }, list = { 'n' },
}
local punctuation_map = {
  ['—'] = '-', ['–'] = '-', ['‘'] = "'", ['’'] = "'", ['“'] = '"', ['”'] = '"',
  ['…'] = '...', [' '] = ' ',
}

local function notice(message, level)
  vim.notify('nvim-claude: ' .. message, level or vim.log.levels.INFO)
end

local function output(text)
  if punctuation == 'allow' then return text end
  for char, substitute in pairs(punctuation_map) do
    text = text:gsub(char, punctuation == 'remove' and '' or substitute)
  end
  return text
end

local function title(label)
  return ' Claude ' .. label .. ' · ' .. model .. ' '
end

local function position(width, height, win)
  local cursor = vim.api.nvim_win_get_cursor(win)
  local pos = vim.fn.win_screenpos(win)
  local row = math.max(0, math.min(vim.o.lines - height - 3, pos[1] + vim.fn.winline() - 1))
  local col = math.max(0, math.min(vim.o.columns - width - 2, pos[2] + cursor[2]))
  return row, col
end

local function float(lines, label, focus, origin, width)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  width = math.max(26, math.min(width or 66, vim.o.columns - 4))
  local height = math.max(1, math.min(#lines, math.max(3, math.floor(vim.o.lines / 3))))
  local row, col = position(width, height, origin)
  local win = vim.api.nvim_open_win(buf, focus, {
    relative = 'editor', row = row, col = col, width = width, height = height,
    border = 'rounded', style = 'minimal', title = title(label), title_pos = 'left',
  })
  return buf, win
end

local function close_answer()
  if answer_window and vim.api.nvim_win_is_valid(answer_window.win) then vim.api.nvim_win_close(answer_window.win, true) end
  if answer_window and vim.api.nvim_win_is_valid(answer_window.origin) then
    vim.api.nvim_set_current_win(answer_window.origin)
  end
  answer_window = nil
end

local function display(text, label, origin)
  if answer_window and vim.api.nvim_win_is_valid(answer_window.win) then close_answer() end
  local buf, win = float(vim.split(text, '\n', { plain = true }), label, false, origin)
  vim.bo[buf].filetype = 'markdown'
  vim.bo[buf].modifiable = false
  answer_window = { buf = buf, win = win, origin = origin, text = text }
  last_result = { text = text, label = label }
  for _, lhs in ipairs({ 'q', '<Esc>' }) do
    vim.keymap.set('n', lhs, close_answer, { buffer = buf, silent = true })
  end
  return answer_window
end

local function update_answer(answer, text)
  if not answer or not vim.api.nvim_buf_is_valid(answer.buf) then return end
  answer.text = text
  last_result = { text = text, label = 'ask' }
  vim.bo[answer.buf].modifiable = true
  local lines = vim.split(text, '\n', { plain = true })
  vim.api.nvim_buf_set_lines(answer.buf, 0, -1, false, lines)
  vim.bo[answer.buf].modifiable = false
  if vim.api.nvim_win_is_valid(answer.win) then
    local opts = vim.api.nvim_win_get_config(answer.win)
    opts.height = math.max(1, math.min(#lines, math.max(3, math.floor(vim.o.lines / 3))))
    vim.api.nvim_win_set_config(answer.win, opts)
  end
end

local function event(message)
  if not active or message.request ~= active.id or message.epoch ~= active.epoch then return end
  local task = active
  if message.type == 'status' then
    notice(task.operation .. ' · ' .. message.message)
    return
  elseif message.type == 'partial' then
    task.raw = task.raw .. (message.text or '')
    if task.operation == 'ask' then
      last_result = { text = output(task.raw), label = 'ask' }
      update_answer(task.answer, output(task.raw))
    end
    return
  end
  active = nil
  if message.type == 'canceled' then return notice('Request canceled') end
  if message.type == 'error' then
    display((message.message or 'Request failed') .. (message.raw and '\n\n' .. message.raw or ''), 'result not applied', task.origin)
    return
  end
  if message.type ~= 'complete' then return end
  if task.operation == 'ask' then
    last_result = { text = output(message.raw or task.raw), label = 'ask' }
    update_answer(task.answer, last_result.text)
    if task.answer and vim.api.nvim_buf_is_valid(task.answer.buf) then vim.bo[task.answer.buf].modifiable = true end
    return
  end
  if message.result.status == 'needs_input' then
    display(message.result.message, 'clarification', task.origin)
    return
  end
  local ok, reason = targets.apply(task.buffer, task.targets, message.result.replacements, output)
  if not ok then
    display(reason .. '\n\n' .. (message.raw or ''), 'result not applied', task.origin)
  elseif task.operation == 'generate' then
    targets.content_action()
  end
end

local function source_text(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  return table.concat(lines, '\n') .. '\n'
end

local function submit(prompt)
  if not prompt_window or prompt_window ~= prompt then return end
  local instruction = table.concat(vim.api.nvim_buf_get_lines(prompt.buf, 0, -1, false), '\n')
  if not instruction:match('%S') then return notice('Enter an instruction', vim.log.levels.WARN) end
  if active or prompt.pending then return notice('Conversation busy; the draft is still open', vim.log.levels.WARN) end
  if not vim.api.nvim_buf_is_valid(prompt.buffer) or (prompt.targets and not targets.valid(prompt.buffer, prompt.targets)) then
    return notice('The captured target changed; open a new prompt', vim.log.levels.WARN)
  end
  local payload = { operation = prompt.operation, instruction = instruction, request = tostring(generation + 1) }
  if prompt.operation ~= 'ask' or prompt.targets then
    local buf = prompt.buffer
    payload.document = { id = 'buffer-' .. buf, filetype = vim.bo[buf].filetype }
    payload.text = source_text(buf)
    payload.revision = tostring(vim.api.nvim_buf_get_changedtick(buf))
    payload.targets = prompt.targets and targets.wire(buf, prompt.targets) or nil
  end
  prompt.pending = true
  bridge.call('begin', payload, function(result, err)
    prompt.pending = false
    if err then return notice(err, vim.log.levels.ERROR) end
    generation = generation + 1
    active = { id = payload.request, epoch = result.epoch, operation = prompt.operation,
      buffer = prompt.buffer, targets = prompt.targets, origin = prompt.origin, raw = '' }
    if prompt_window == prompt then
      if vim.api.nvim_win_is_valid(prompt.win) then vim.api.nvim_win_close(prompt.win, true) end
      prompt_window = nil
      if vim.api.nvim_win_is_valid(prompt.origin) then vim.api.nvim_set_current_win(prompt.origin) end
    end
    if prompt.operation == 'ask' then active.answer = display('…', 'ask · streaming', prompt.origin) end
    if prompt.operation == 'ask' and prompt.targets then targets.ask_selected(prompt.buffer, prompt.targets)
    else targets.content_action() end
  end)
end

local function prompt(operation, selected, insert_mode)
  if prompt_window then return notice('A prompt is already open', vim.log.levels.WARN) end
  local origin = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()
  local captured
  if selected then
    captured = targets.selection(buf)
    if not captured then return notice('No valid visual selection', vim.log.levels.WARN) end
  elseif operation == 'replace' then
    captured = targets.previous(buf)
    if not captured then return notice('Select text before replacing it', vim.log.levels.WARN) end
  elseif operation == 'generate' then
    captured = targets.insertion(buf, insert_mode)
  elseif operation == 'ask_previous' then
    captured = targets.ask_previous(buf)
    if not captured then return notice('No selected ask target remains in this buffer', vim.log.levels.WARN) end
  end
  if operation == 'ask_previous' then operation = 'ask' end
  local text_buf, win = float({ '' }, operation, true, origin, 58)
  vim.bo[text_buf].buftype = 'nofile'
  prompt_window = { buf = text_buf, win = win, origin = origin, buffer = buf, targets = captured, operation = operation }
  local this = prompt_window
  local function dismiss()
    if not prompt_window or prompt_window ~= this then return end
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    prompt_window = nil
    if vim.api.nvim_win_is_valid(origin) then vim.api.nvim_set_current_win(origin) end
  end
  vim.keymap.set({ 'n', 'i' }, '<C-s>', function() submit(this) end, { buffer = text_buf, silent = true })
  vim.keymap.set('n', '<CR>', function() submit(this) end, { buffer = text_buf, silent = true })
  vim.keymap.set('n', '<Esc>', dismiss, { buffer = text_buf, silent = true })
  vim.api.nvim_create_autocmd('TextChangedI', {
    buffer = text_buf, callback = function()
      if vim.api.nvim_win_is_valid(win) then
        local opts = vim.api.nvim_win_get_config(win)
        opts.height = math.min(10, math.max(1, vim.api.nvim_buf_line_count(text_buf)))
        vim.api.nvim_win_set_config(win, opts)
      end
    end,
  })
  vim.cmd('startinsert')
end

local function invoke(method, params, callback)
  bridge.call(method, params or {}, function(result, err)
    if err then return notice(err, vim.log.levels.ERROR) end
    if result and result.config then model = result.config.model end
    if callback then callback(result) end
  end)
end

local presets = { 'model default', '50k', '90k', '100k', '124k', '150k', '164k', '200k', '224k', '256k', '258k', '274k', '278k', '300k', '374k', '378k', '384k', '412k', '456k', '500k', '512k', '600k', '650k', '700k', '750k', '800k', '850k', '900k', '950k', '980k' }
local function budget_choice(chosen, effort)
  vim.ui.select(presets, { prompt = 'Context budget' }, function(limit)
    if not limit then return end
    local count = limit == 'model default' and vim.NIL or tonumber(limit:sub(1, -2)) * 1000
    invoke('configure', { model = chosen, effort = effort or vim.NIL, context_limit_tokens = count }, function()
      notice('Model: ' .. chosen .. ' · budget: ' .. limit)
    end)
  end)
end

local function picker()
  invoke('models', {}, function(result)
    local models = result.models or {}
    if #models == 0 then return notice('Runtime announced no model catalogue; use :NvClaude model manual') end
    vim.ui.select(models, { prompt = 'Claude model', format_item = function(item)
      return (item.displayName or item.description or item.value or item.id) .. ' · ' .. (item.value or item.id or '')
    end }, function(choice)
      if not choice then return end
      local name = choice.value or choice.id
      local efforts = choice.supportsEffort and choice.supportedEffortLevels or nil
      if not efforts or #efforts == 0 then return budget_choice(name, nil) end
      vim.ui.select(efforts, { prompt = 'Effort', format_item = tostring }, function(effort)
        if effort then budget_choice(name, effort) end
      end)
    end)
  end)
end

local function manual()
  vim.ui.input({ prompt = 'Model expression: ', default = model }, function(value)
    if value and value ~= '' then invoke('configure', { expression = value }) end
  end)
end

local function list()
  invoke('list', {}, function(items)
    if #items == 0 then return notice('No saved conversations') end
    vim.ui.select(items, { prompt = 'Saved conversations', format_item = function(item)
      return os.date('%y:%m:%d:%H:%M:%S', item.created) .. ' - ' .. item.title .. ' [' .. item.id:sub(1, 8) .. ']'
    end }, function(item)
      if item then invoke('resume', { id = item.id }) end
    end)
  end)
end

local function info()
  invoke('state', {}, function(state)
    local cfg = state.config
    local lines = {
      'Model: ' .. cfg.model .. ' · effort ' .. tostring(cfg.effort),
      'Local budget: ' .. tostring(cfg.context_limit_tokens or 'model default'),
      'Budget status: ' .. state.budget,
      'Context occupancy: ' .. tostring(state.occupancy and state.occupancy.totalTokens or 'not measured'),
      'Cumulative usage: ' .. vim.inspect(state.usage),
      'Saved: ' .. tostring(state.saved) .. ' · sticky: ' .. tostring(state.sticky),
      'SDK: ' .. tostring(state.sdk) .. ' · CLI: ' .. tostring(state.runtime.claude_code_version or 'not connected'),
      'Cache: ' .. state.cache,
      'Authentication/billing: runtime-managed; not verified by this plugin',
    }
    display(table.concat(lines, '\n'), 'info', vim.api.nvim_get_current_win())
  end)
end

local function login()
  invoke('state', {}, function(state)
    if not state.cli then return notice('Bundled Claude Code CLI unavailable', vim.log.levels.ERROR) end
    vim.cmd('tabnew')
    vim.fn.termopen({ state.cli, 'auth', 'login' })
    vim.cmd('startinsert')
  end)
end

local function system_modify()
  invoke('system_get', {}, function(result)
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, 'nvim-claude://system-' .. buf)
    vim.bo[buf].buftype = 'acwrite'
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(result.text, '\n', { plain = true }))
    vim.api.nvim_create_autocmd('BufWriteCmd', { buffer = buf, callback = function()
      invoke('system', { text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n') }, function()
        vim.bo[buf].modified = false
        notice('System prompt changed for subsequent requests')
      end)
    end })
    vim.api.nvim_set_current_buf(buf)
  end)
end
local function show_last_result()
  if not last_result then return notice('No answer or result is available') end
  display(last_result.text, last_result.label, vim.api.nvim_get_current_win())
end

local function command(args)
  local words = vim.split(args.args, '%s+', { trimempty = true })
  local action, sub = words[1] or 'ask', words[2]
  if action == 'ask' then return prompt(sub == 'previous' and 'ask_previous' or 'ask', false) end
  if action == 'replace' or action == 'generate' then return prompt(action, false) end
  if action == 'model' then return sub == 'manual' and manual() or picker() end
  if action == 'list' then return list() end
  if action == 'info' then return info() end
  if action == 'cancel' then return invoke('cancel') end
  if action == 'login' then return login() end
  if action == 'update' then
    if active then return notice('Cancel or finish this request before updating the SDK', vim.log.levels.WARN) end
    return bridge.update(function(_, err)
      if err then notice(err, vim.log.levels.ERROR) else notice('SDK environment updated') end
    end)
  end
  if action == 'new' or action == 'clear' or action == 'save' or action == 'compact' then return invoke(action) end
  if action == 'sticky' then return invoke('sticky', { enabled = sub == 'on' and true or sub == 'off' and false or nil }) end
  if action == 'result' then return show_last_result() end
  if action == 'watermarks' and ({ allow = true, remove = true, replace = true })[sub] then
    punctuation = sub
    return notice('Punctuation policy: ' .. sub)
  end
  if action == 'system' then
    if sub == 'modify' then return system_modify() end
    if sub == 'default' then return invoke('system', { text = '' }) end
  end
  notice('Unknown command: ' .. action, vim.log.levels.ERROR)
end

local function completion(arglead, cmdline)
  local words = vim.split(cmdline, '%s+', { trimempty = true })
  local choices
  if #words <= 2 then choices = { 'ask', 'replace', 'generate', 'cancel', 'login', 'result', 'model', 'new', 'clear', 'save', 'sticky', 'list', 'info', 'compact', 'update', 'system', 'watermarks' }
  elseif words[2] == 'watermarks' then choices = { 'allow', 'remove', 'replace' }
  elseif words[2] == 'sticky' then choices = { 'on', 'off' }
  elseif words[2] == 'system' then choices = { 'modify', 'default' }
  elseif words[2] == 'ask' then choices = { 'previous' }
  elseif words[2] == 'model' then choices = { 'manual' }
  else choices = {} end
  return vim.tbl_filter(function(item) return vim.startswith(item, arglead) end, choices)
end

local actions = {
  replace = function() prompt('replace', vim.fn.mode():match('[vV\22]') ~= nil) end,
  replace_short = function() prompt('replace', vim.fn.mode():match('[vV\22]') ~= nil) end,
  ask = function()
    local selected = vim.fn.mode():match('[vV\22]') ~= nil
    if selected then prompt('ask', true)
    elseif targets.ask_previous(vim.api.nvim_get_current_buf()) then prompt('ask_previous', false)
    else prompt('ask', false) end
  end,
  generate = function() prompt('generate', false) end,
  generate_insert = function() prompt('generate', false, true) end,
  model = picker, model_manual = manual, clear = function() invoke('clear') end,
  new = function() invoke('new') end, sticky = function() invoke('sticky') end,
  save = function() invoke('save') end, info = info, list = list,
}

function M.setup(opts)
  opts = opts or {}
  bridge.setup(opts, event)
  if configured then
    for _, mapping in ipairs(owned_maps) do
      local installed = vim.fn.maparg(mapping.key, mapping.mode, false, true)
      if installed.desc == 'NvClaude ' .. mapping.action then vim.keymap.del(mapping.mode, mapping.key) end
    end
    owned_maps = {}
  end
  configured = true
  pcall(vim.api.nvim_del_user_command, 'NvClaude')
  vim.api.nvim_create_user_command('NvClaude', command, { nargs = '*', complete = completion, desc = 'Claude inline editor' })
  local group = vim.api.nvim_create_augroup('NvClaudeBridge', { clear = true })
  vim.api.nvim_create_autocmd('VimLeavePre', { group = group, callback = bridge.stop })
  if opts.keys ~= false then
    for action, fallback in pairs(defaults) do
      local configured_key
      if type(opts.keys) == 'table' then configured_key = opts.keys[action] end
      local key = configured_key
      if key == nil then key = fallback end
      if key ~= false then
        for _, mode in ipairs(modes[action]) do
          if configured_key ~= nil or vim.fn.maparg(key, mode) == '' then
            vim.keymap.set(mode, key, actions[action], { silent = true, desc = 'NvClaude ' .. action })
            owned_maps[#owned_maps + 1] = { mode = mode, key = key, action = action }
          end
        end
      end
    end
  end
  return M
end

return M
