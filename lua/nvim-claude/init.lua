local M = {}
local api = vim.api
local targets = require('nvim-claude.targets')
local rpc = require('nvim-claude.rpc')
local ui = require('nvim-claude.ui')
local state = { generation = 0, busy = false, remembered = {}, ask = nil, action = nil, maps = {} }
local opts = {}
local defaults = { replace = '<leader>cc', replace_short = '<leader>c', ask = '<leader>ca',
  generate = '<leader>ci', generate_insert = false, model = '<leader>cm', model_manual = '<leader>cM',
  clear = '<leader>cC', new = '<leader>cn', sticky = '<leader>cS', save = '<leader>cs',
  info = '<leader>cx', list = '<leader>cl' }
local commands = { 'ask', 'replace', 'generate', 'model', 'clear', 'new', 'sticky', 'save',
  'info', 'list', 'resume', 'compact', 'cancel', 'system', 'watermarks', 'login', 'update', 'answer' }

local function message(text, level)
  vim.notify('nvim-claude: ' .. text, level or vim.log.levels.INFO)
end

local function release_unused(target)
  if target and target ~= state.remembered[target.buf] and target ~= state.ask then targets.release(target) end
end

local function forget_ask()
  local previous = state.ask
  state.ask = nil
  release_unused(previous)
end

local function remember(target)
  local previous = state.remembered[target.buf]
  state.remembered[target.buf] = target
  release_unused(previous)
end

local function events(method, params)
  if method == 'setup' then
    vim.g.nvclaude_status = params.message
    api.nvim_echo({ { 'Claude: ' .. params.message, 'ModeMsg' } }, false, {})
    return
  end
  if method == 'status' and (not params.generation or params.generation == state.generation) then
    vim.g.nvclaude_status = params.message
    vim.api.nvim_echo({ { 'Claude: ' .. params.message, 'ModeMsg' } }, false, {})
  elseif method == 'text' and state.busy and params.generation == state.generation then
    state.raw_preview = params.text
    if state.last_result then state.last_result.text = params.text end
    if state.view then state.view.update(params.text) end
  end
end

local function call(method, params, callback)
  rpc.call(opts, events, method, params or {}, function(result, err)
    if err then message(err, vim.log.levels.ERROR) end
    if callback then callback(result, err) end
  end)
end

local function show(title, text, origin, enter)
  state.last_result = { title = title, text = text, origin = origin }
  state.view = ui.result(title, text, origin, enter)
  return state.view
end

local function cancel()
  state.generation = state.generation + 1
  rpc.cancelled_generation = state.generation
  state.busy = false
  vim.g.nvclaude_status = 'cancelled'
  if rpc.job then rpc.send('cancel', {}, function() end) end
end

function M.invoke(operation, use_previous, command_general)
  if not M.configured then M.setup({}) end
  local origin, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
  local mode = vim.fn.mode()
  local visual = mode == 'v' or mode == 'V' or mode == '\22'
  local target
  if operation == 'generate' then
    target = targets.capture(buf, nil, true)
  elseif visual then
    target = targets.capture(buf, mode)
  elseif operation == 'replace' then
    target = state.remembered[buf]
    if not targets.valid(target, buf) then message('Select text before replacing'); return end
  elseif use_previous or (not command_general and state.action == 'selected_ask') then
    if targets.valid(state.ask, buf) then target = state.ask
    elseif use_previous then message('No valid selected-ask target in this buffer'); return end
  end
  if visual then vim.cmd('normal! \27') end
  local label = opts.model_config.model
  ui.prompt(operation .. ' · ' .. label, origin, function(instruction)
    if instruction == '' then message('Enter an instruction'); return false end
    if state.busy then message('Conversation is busy; draft retained'); return false end
    local params = { operation = operation, instruction = instruction }
    if target then
      local serialized, reason = targets.serialize(target)
      if not serialized then message(reason); return false end
      local text = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
      params.document = { id = 'buffer-' .. buf, filetype = vim.bo[buf].filetype,
        revision = tostring(api.nvim_buf_get_changedtick(buf)), text = text }
      params.targets, params.block = serialized, target.block or false
      params.whole_document = opts.context == 'full'
    end
    state.generation = state.generation + 1
    local generation = state.generation
    params.generation = generation
    state.busy, state.raw_preview = true, ''
    if operation == 'ask' then
      if state.ask ~= target then forget_ask() end
      state.action, state.ask = target and 'selected_ask' or 'general_ask', target
    else
      forget_ask()
      state.action = operation
    end
    if operation == 'replace' then remember(target) end
    if state.view then state.view = nil end
    if operation == 'ask' then show('Claude answer', '', origin, false) end
    call('request', params, function(result, err)
      if generation ~= state.generation then release_unused(target); return end
      state.busy = false
      vim.g.nvclaude_status = err and 'failed' or 'complete'
      if err then
        local text = (state.raw_preview or '') .. '\n\nRequest failed: ' .. err
        if state.view then state.view.update(text) end
        show('Claude request failed', text, origin, false)
        release_unused(target)
        return
      end
      if operation == 'ask' then
        if state.view then state.view.update(result.text) end
        state.last_result = { title = 'Claude answer', text = result.text, origin = origin }
      else
        local edit = result.edit
        if edit.status == 'needs_input' then
          show('Claude needs input', edit.message, origin, false)
          release_unused(target)
          return
        end
        local ok, reason = targets.apply(target, edit.replacements)
        if not ok then
          show('Claude result not applied', reason .. '\n\n' .. result.text, origin, false)
          release_unused(target)
        else remember(target); message(operation .. ' complete') end
      end
    end)
    return true
  end, function()
    release_unused(target)
  end)
end

local function model_picker()
  call('models', {}, function(result, err)
    if err then return end
    if #result.models == 0 then message('Runtime supplies no catalogue. Use :NvClaude model manual'); return end
    vim.ui.select(result.models, { prompt = 'Claude model', format_item = function(model)
      return (model.displayName or model.value) .. ' · ' .. (model.resolvedModel or model.value)
    end }, function(model)
      if not model then return end
      local function budget(effort)
        local limits = { 'model default' }
        for _, value in ipairs(result.presets) do limits[#limits + 1] = tostring(value / 1000):gsub('%.0$', '') .. 'k' end
        vim.ui.select(limits, { prompt = 'Local prompt ceiling, also constrained by physical context' }, function(limit)
          if not limit then return end
          local config = { model = model.value, effort = effort, context_limit_tokens = limit == 'model default' and vim.NIL or tonumber(limit:sub(1, -2)) * 1000 }
          call('model', config, function(value, error)
            if not error then opts.model_config = value; message('Model configuration updated') end
          end)
        end)
      end
      if model.supportsEffort and model.supportedEffortLevels and #model.supportedEffortLevels > 0 then
        vim.ui.select(model.supportedEffortLevels, { prompt = 'Reasoning effort' }, function(effort) if effort then budget(effort) end end)
      else budget(nil) end
    end)
  end)
end

local function manual_model()
  vim.ui.input({ prompt = 'Claude model expression: ', default = opts.model_config.model }, function(expression)
    if expression and expression ~= '' then
      call('model', { expression = expression }, function(config, err)
        if not err then opts.model_config = config; message('Selected ' .. config.model) end
      end)
    end
  end)
end

local function change_context(method, params)
  cancel()
  forget_ask()
  state.action = nil
  call(method, params, function(result, err)
    if not err then
      if result.config then opts.model_config = result.config end
      message(vim.inspect(result))
    end
  end)
end

local function system_modify()
  call('info', {}, function(info, err)
    if err then return end
    local buf = api.nvim_create_buf(false, true)
    api.nvim_set_current_buf(buf)
    vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].filetype = 'acwrite', 'wipe', 'text'
    api.nvim_buf_set_name(buf, 'nvim-claude://system/' .. buf)
    api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(info.system_prompt, '\n', { plain = true }))
    api.nvim_create_autocmd('BufWriteCmd', { buffer = buf, callback = function()
      if state.busy then message('Wait for the active turn before changing the prompt'); return end
      call('system', { prompt = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), '\n') }, function(result, error)
        if not error then vim.bo[buf].modified = false; message(result.message) end
      end)
    end })
    vim.bo[buf].modified = false
  end)
end

function M.command(args)
  local parts = vim.split(args or '', '%s+', { trimempty = true })
  local action, sub = parts[1] or 'ask', parts[2]
  if action == 'ask' then M.invoke('ask', sub == 'previous', true)
  elseif action == 'replace' or action == 'generate' then M.invoke(action)
  elseif action == 'cancel' then cancel()
  elseif action == 'new' or action == 'clear' then change_context(action, {})
  elseif action == 'resume' then change_context('resume', { id = sub })
  elseif action == 'model' then
    if sub == 'manual' then manual_model()
    elseif sub then call('model', { expression = table.concat(parts, ' ', 2) }, function(config, err) if not err then opts.model_config = config end end)
    else model_picker() end
  elseif action == 'info' then
    local origin = api.nvim_get_current_win()
    call('info', {}, function(info, err)
      if not err then info.system_prompt = nil; show('Claude information', vim.inspect(info), origin) end
    end)
  elseif action == 'list' then
    call('list', {}, function(records, err)
      if err then return end
      vim.ui.select(records, { prompt = 'Saved Claude conversations', format_item = function(item) return item.title .. ' [' .. item.id .. ']' end },
        function(item) if item then change_context('resume', { id = item.id }) end end)
    end)
  elseif action == 'sticky' then
    if sub and sub ~= 'on' and sub ~= 'off' then message('Use sticky on or off'); return end
    call('sticky', sub and { enabled = sub == 'on' } or {}, function(result, err) if not err then message(vim.inspect(result)) end end)
  elseif action == 'system' then
    if sub == 'modify' then system_modify()
    elseif sub == 'default' then
      if state.busy then message('Wait for the active turn'); return end
      call('system', {}, function(result, err) if not err then message(result.message) end end)
    else message('Use system modify or system default') end
  elseif action == 'watermarks' then
    call('watermarks', { policy = sub or 'allow' }, function(result, err) if not err then message('Punctuation: ' .. result.policy) end end)
  elseif action == 'login' then
    call('info', {}, function(info, err)
      if err then return end
      vim.cmd('botright new')
      vim.fn.jobstart({ info.cli_path, 'auth', 'login' }, { term = true })
      vim.cmd('startinsert')
    end)
  elseif action == 'update' then
    if state.busy then message('Cancel the active request before updating'); return end
    rpc.stop(); rpc.closing = false
    opts.update = true
    rpc.start(opts, events, function(_, err) opts.update = false; if not err then message('Runtime updated') end end)
  elseif action == 'answer' then
    local result = state.last_result
    if result then show(result.title, result.text, result.origin) else message('No result yet') end
  elseif action == 'save' or action == 'compact' then
    if state.busy then message('Conversation is busy'); return end
    call(action, {}, function(result, err) if not err then message(vim.inspect(result)) end end)
  else message('Unknown command: ' .. action) end
end

function M.setup(options)
  options = options or {}
  opts = vim.tbl_deep_extend('force', { model_config = { model = 'claude-haiku-5-5', effort = 'low', context_limit_tokens = 100000 }, context = 'excerpt' }, options)
  -- Remove only mappings still owned by this module, never a later user override.
  for _, mapping in ipairs(state.maps) do
    local current = vim.fn.maparg(mapping.lhs, mapping.mode, false, true)
    if current.callback == mapping.callback then pcall(vim.keymap.del, mapping.mode, mapping.lhs) end
  end
  state.maps = {}
  api.nvim_create_user_command('NvClaude', function(command) M.command(command.args) end, {
    nargs = '*', force = true,
    complete = function(lead, command)
      local before = command:sub(1, #command - #lead)
      local values = commands
      if before:match('watermarks%s+') then values = { 'allow', 'replace', 'remove' }
      elseif before:match('system%s+') then values = { 'modify', 'default' }
      elseif before:match('sticky%s+') then values = { 'on', 'off' }
      elseif before:match('ask%s+') then values = { 'previous' }
      elseif before:match('model%s+') then values = { 'manual' } end
      return vim.tbl_filter(function(value) return value:sub(1, #lead) == lead end, values)
    end,
  })
  local group = api.nvim_create_augroup('NvClaudeLifecycle', { clear = true })
  api.nvim_create_autocmd('VimLeavePre', { group = group, callback = rpc.stop })
  api.nvim_create_autocmd('BufEnter', { group = group, callback = function(event)
    if vim.bo[event.buf].buftype == '' and state.ask and state.ask.buf ~= event.buf then
      forget_ask()
      state.action = nil
    end
  end })
  api.nvim_create_autocmd('BufDelete', { group = group, callback = function(event)
    local previous = state.remembered[event.buf]
    state.remembered[event.buf] = nil
    if state.ask and state.ask.buf == event.buf then forget_ask(); state.action = nil end
    release_unused(previous)
  end })
  if options.keys ~= false then
    local keys = type(options.keys) == 'table' and options.keys or {}
    for action, default in pairs(defaults) do
      local lhs = keys[action] == nil and default or keys[action]
      if lhs and lhs ~= '' then
        local modes = (action == 'replace' or action == 'replace_short' or action == 'ask') and { 'n', 'x' }
          or (action == 'generate_insert' and { 'i' } or { 'n' })
        for _, mode in ipairs(modes) do
          local actual = action == 'replace_short' and 'replace' or (action == 'generate_insert' and 'generate' or action)
          local callback = function()
            if actual == 'replace' or actual == 'ask' or actual == 'generate' then M.invoke(actual)
            else M.command(actual == 'model_manual' and 'model manual' or actual) end
          end
          if keys[action] ~= nil or vim.fn.maparg(lhs, mode) == '' then
            vim.keymap.set(mode, lhs, callback, { silent = true, desc = 'Claude ' .. actual })
            state.maps[#state.maps + 1] = { lhs = lhs, mode = mode, callback = callback }
          end
        end
      end
    end
  end
  M.configured = true
end

return M
