local bridge = require('nvim-claude.bridge')
local targets = require('nvim-claude.target')
local context = require('nvim-claude.context')
local model = require('nvim-claude.model')
local ui = require('nvim-claude.ui')
local M = {}
local config = { model = 'claude-haiku-5-5', effort = 'low', context_limit_tokens = 100000 }
local defaults = { replace = '<leader>cc', replace_short = '<leader>c', ask = '<leader>ca',
  generate = '<leader>ci', generate_insert = false, model = '<leader>cm',
  model_manual = '<leader>cM', clear = '<leader>cC', new = '<leader>cn',
  sticky = '<leader>cS', save = '<leader>cs', info = '<leader>cx', list = '<leader>cl' }
local installed_maps = {}
local active, last_action, remembered, selected_ask = nil, nil, {}, nil
local epoch, baseline_epoch, serial, runtime_identity, conversation_id = 0, nil, 0, nil, nil
local punctuation = 'allow'
local punctuation_map = { ['—'] = '-', ['–'] = '-', ['‘'] = "'", ['’'] = "'",
  ['“'] = '"', ['”'] = '"', ['…'] = '...', [' '] = ' ' }
local system_prompt
local override

local function notify(message, level)
  vim.notify('nvim-claude: ' .. tostring(message), level or vim.log.levels.INFO)
end
local function error_message(err)
  return type(err) == 'table' and (err.message or vim.inspect(err)) or tostring(err)
end
local function normalized(text, policy)
  policy = policy or punctuation
  if policy == 'allow' then return text end
  for symbol, replacement in pairs(punctuation_map) do
    text = text:gsub(symbol, policy == 'remove' and '' or replacement)
  end
  return text
end
local function prompt_resource()
  if system_prompt then return system_prompt end
  local resource = vim.api.nvim_get_runtime_file('resources/system.txt', false)[1]
  if not resource then return nil, 'The plugin system prompt resource is missing' end
  local fd = io.open(resource, 'r')
  if not fd then return nil, 'Cannot read the plugin system prompt resource' end
  system_prompt = fd:read('*a'); fd:close()
  return system_prompt
end
local function current_prompt() return override or prompt_resource() end
local function valid(target)
  local positions = targets.inspect(target)
  return positions ~= nil
end
local function clear_target(target)
  if target then targets.release(target) end
end
local function replace_remembered(buf, target)
  local old = remembered[buf]
  if old and old ~= target and old ~= selected_ask then clear_target(old) end
  remembered[buf] = target
end
local function reserve(operation, selected, insert_mode, previous, force_general)
  local buf, origin = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  local target, err
  if selected then
    target, err = targets.visual(buf)
  elseif operation == 'ask' and previous then
    target = selected_ask and selected_ask.buf == buf and valid(selected_ask) and selected_ask or nil
    if not target then err = 'No previous selected-ask target remains in this buffer' end
  elseif operation == 'replace' and previous then
    target = remembered[buf]
    if not valid(target) then target, err = nil, 'Select text first, then invoke replace' end
  elseif operation == 'generate' then
    target, err = targets.insertion(buf, insert_mode)
  elseif operation == 'ask' and not force_general and selected_ask and selected_ask.buf == buf and
    last_action == 'selected-ask' and valid(selected_ask) then
    target = selected_ask
  end
  if (operation == 'replace' or operation == 'generate' or previous) and not target then
    notify(err or 'Select text first', vim.log.levels.WARN); return
  end
  if err then notify(err, vim.log.levels.WARN); return end
  ui.prompt({ origin = origin, operation = operation, model = model.label(config),
    dismiss = function()
      if selected and target and target ~= remembered[buf] and target ~= selected_ask then clear_target(target) end
      if operation == 'generate' then clear_target(target) end
    end,
    submit = function(instruction)
      if active then notify('Conversation busy; your draft remains in the prompt', vim.log.levels.WARN); return false end
      M.turn(operation, instruction, target, origin, selected)
      return true
    end,
  })
end

local function parse_edit(text, target, policy)
  local ok, envelope = pcall(vim.json.decode, text)
  if not ok or type(envelope) ~= 'table' then return nil, 'Claude returned invalid edit JSON' end
  if envelope.status == 'needs_input' then
    if type(envelope.message) ~= 'string' or envelope.message == '' or envelope.replacements ~= nil then
      return nil, 'Malformed clarification from Claude'
    end
    return false, envelope.message
  end
  if envelope.status ~= 'ok' or type(envelope.replacements) ~= 'table' or
    #envelope.replacements ~= #target.segments then
    return nil, 'Claude returned an incomplete edit envelope'
  end
  local ids, edits = {}, {}
  for _, item in ipairs(target.segments) do ids[item.id] = true end
  for _, item in ipairs(envelope.replacements) do
    if type(item) ~= 'table' or not ids[item.id] or type(item.text) ~= 'string' then
      return nil, 'Unknown or malformed replacement target'
    end
    ids[item.id] = nil
    if target.kind == 'block' and item.text:find('\n', 1, true) then
      return nil, 'Blockwise output cannot include a newline'
    end
    edits[#edits + 1] = { id = item.id, text = normalized(item.text, policy) }
  end
  if next(ids) then return nil, 'Duplicate or missing replacement target' end
  return edits
end

local function finish_request(turn, err, result)
  if active ~= turn then return end
  active = nil
  local stale = turn.epoch ~= epoch
  if turn.cancelled or stale then
    context.invalidate(turn.document_id)
    if turn.temporary then clear_target(turn.target) end
  elseif err or not result or type(result.text) ~= 'string' then
    context.invalidate(turn.document_id)
    local text = err and error_message(err) or 'Bridge returned no completed response'
    ui.update(turn.view, turn.partial .. '\n\n' .. text, 'failed')
    notify(text, vim.log.levels.ERROR)
    if turn.temporary then clear_target(turn.target) end
  else
    if result.context_reset then
      context.reset()
    elseif result.accepted_context == true and turn.snapshot then
      turn.snapshot.confirm()
    end
    if result.baseline_epoch ~= nil then baseline_epoch = result.baseline_epoch end
    if result.active_id then conversation_id = result.active_id end
    if result.resolved_model then turn.resolved_model = result.resolved_model end
    if turn.operation == 'ask' then
      ui.update(turn.view, normalized(result.text, turn.policy), 'complete')
    else
      local replacements, why = parse_edit(result.text, turn.target, turn.policy)
      if replacements == false then
        ui.update(turn.view, why, 'needs input')
      elseif not replacements then
        ui.update(turn.view, result.text .. '\n\n' .. why, 'not applied')
      else
        local applied, apply_error = targets.apply(turn.target, replacements)
        if not applied then
          ui.update(turn.view, result.text .. '\n\nNot applied: ' .. apply_error, 'not applied')
        else
          ui.update(turn.view, apply_error or 'Edit applied to the captured buffer', 'complete')
          if turn.operation == 'replace' then replace_remembered(turn.target.buf, turn.target)
          else clear_target(turn.target) end
        end
      end
      if replacements == false or not replacements then
        if turn.temporary then clear_target(turn.target) end
      end
    end
  end
  if turn.after then turn.after() end
end

function M.turn(operation, instruction, target, origin, selected)
  local prompt, prompt_err = current_prompt()
  if not prompt then notify(prompt_err, vim.log.levels.ERROR); return end
  if operation == 'ask' and target then
    if selected and selected_ask and selected_ask ~= target and selected_ask ~= remembered[selected_ask.buf] then
      clear_target(selected_ask)
    end
    selected_ask, last_action = target, 'selected-ask'
  else
    if selected_ask and selected_ask ~= remembered[selected_ask.buf] then clear_target(selected_ask) end
    selected_ask, last_action = nil, operation
  end
  serial = serial + 1; epoch = epoch + 1
  local turn = { epoch = epoch, operation = operation, target = target, origin = origin,
    temporary = selected or operation == 'generate', partial = '', serial = serial, policy = punctuation }
  active = turn
  turn.view = ui.answer({ origin = origin, title = operation .. ' · ' .. config.model, status = 'setting up' })
  bridge.ensure(function(ready_err)
    if active ~= turn then return end
    if ready_err then return finish_request(turn, { message = ready_err }) end
    if runtime_identity ~= bridge.runtime() then
      runtime_identity = bridge.runtime()
      baseline_epoch, conversation_id = nil, nil
      context.reset()
    end
    bridge.rpc('session', { action = 'info' }, function(info_err, info)
      if active ~= turn then return end
      if info_err then return finish_request(turn, info_err) end
      if baseline_epoch ~= info.baseline_epoch or conversation_id ~= info.active_id then
        context.reset()
        baseline_epoch, conversation_id = info.baseline_epoch, info.active_id
      end
      if target and not valid(target) then
        return finish_request(turn, { message = 'Target changed before dispatch' })
      end
      local source = target and target.buf or vim.api.nvim_get_current_buf()
      turn.snapshot = context.prepare(source, target, operation,
        config.context_limit_tokens and config.context_limit_tokens * 2 or nil)
      turn.document_id = turn.snapshot and turn.snapshot.document.id
      local request = { operation = operation, instruction = instruction,
        coordinates = 'zero-based UTF-8 bytes; end-exclusive' }
      if turn.snapshot then
        request.document, request.context = turn.snapshot.document, turn.snapshot.context
        request.targets = targets.envelope(target, targets.inspect(target))
      end
      ui.update(turn.view, turn.partial,
        type(info.session_id) == 'string' and 'continued' or 'new session')
      turn.id = bridge.rpc('turn', { epoch = turn.epoch, operation = operation,
        request = request, model = config.model, effort = config.effort,
        context_limit_tokens = config.context_limit_tokens,
        system_prompt = prompt, baseline_epoch = baseline_epoch }, function(turn_err, result)
        finish_request(turn, turn_err, result)
      end)
    end)
  end)
end
bridge.events(function(event)
  if not active or active.id ~= event.id or active.epoch ~= event.epoch or active.cancelled then return end
  if event.type == 'partial' then
    active.partial = event.text or ''
    if active.operation == 'ask' then ui.update(active.view, normalized(active.partial, active.policy), 'streaming')
    else ui.update(active.view, active.partial, 'preview, not applied') end
  elseif event.type == 'status' then
    ui.update(active.view, active.operation == 'ask' and normalized(active.partial, active.policy) or active.partial,
      event.status or 'working')
  end
end)

function M.cancel(after)
  if not active then if after then after() else notify('No active request') end; return end
  local turn = active
  turn.cancelled = true; epoch = epoch + 1
  turn.after = after
  ui.update(turn.view, turn.partial .. '\n\nCanceled; no source edit will be applied.', 'canceled')
  if turn.id then
    bridge.cancel(turn.id, turn.epoch, function(err)
      if err then notify(error_message(err), vim.log.levels.WARN) end
    end)
  else
    active = nil
    if turn.temporary then clear_target(turn.target) end
    if after then after() end
  end
end
local function session(action, args, callback)
  local function run()
    bridge.rpc('session', vim.tbl_extend('force', { action = action }, args or {}), function(err, result)
      if err then notify(error_message(err), vim.log.levels.ERROR); return end
      if action == 'new' or action == 'clear' or action == 'resume' or action == 'compact' then
        context.reset(); baseline_epoch = nil
      end
      if callback then callback(result or {})
      else notify(action .. ' complete') end
    end)
  end
  if active and (action == 'new' or action == 'clear' or action == 'resume' or action == 'compact') then
    M.cancel(run)
  else run() end
end

local function list()
  session('list', nil, function(result)
    local conversations = result.conversations or {}
    if #conversations == 0 then notify('No saved conversations'); return end
    vim.ui.select(conversations, {
      prompt = 'Resume a saved Claude conversation',
      format_item = function(item)
        return item.title or ('Untitled [' .. tostring(item.id) .. ']')
      end,
    }, function(item)
      if item then session('resume', { id = item.id }, function() notify('Resumed ' .. item.id) end) end
    end)
  end)
end
local function info()
  session('info', nil, function(result)
    local budget = type(result.budget_status) == 'table' and result.budget_status or {}
    local effective = config.context_limit_tokens
    if type(budget.physical_context_window) == 'number' then
      effective = effective and math.min(effective, budget.physical_context_window)
        or budget.physical_context_window
    end
    local lines = { 'Model: ' .. model.label(config),
      'Resolved model: ' .. tostring(result.resolved_model or 'not reported'),
      'Context occupancy: ' .. vim.inspect(result.occupancy or 'not measured'),
      'Requested local limit: ' .. tostring(config.context_limit_tokens or 'model default'),
      'Budget enforcement: ' .. tostring(budget.status or 'not established') ..
        (type(budget.reason) == 'string' and ' (' .. budget.reason .. ')' or ''),
      'Physical window: ' .. tostring(budget.physical_context_window or 'not reported'),
      'Effective constraint: ' .. tostring(effective or 'not reported'),
      'Usage across turns: ' .. vim.inspect(result.usage or 'not reported'),
      'Retention: ' .. tostring(result.retention or 'ephemeral'),
      'Sticky: ' .. tostring(result.sticky or false),
      'Cache estimate/provenance: ' .. vim.inspect(result.cache or 'not available'),
      'Python: ' .. tostring(result.python or 'not reported'),
      'SDK: ' .. tostring(result.sdk or 'not reported'),
      'CLI: ' .. tostring(result.cli or 'not reported') }
    ui.message('Claude session info', lines, vim.api.nvim_get_current_win())
  end)
end
local function effort_options(item, done)
  local choices = item.efforts
  if not choices or #choices == 0 then done(nil); return end
  local options = vim.list_extend({ 'No effort setting' }, choices)
  vim.ui.select(options, { prompt = 'Claude effort' }, function(value)
    if not value then return end
    done(value == 'No effort setting' and vim.NIL or value)
  end)
end
local function budget_options(done)
  local options = { { title = 'Model default', tokens = vim.NIL } }
  for _, tokens in ipairs(model.presets) do
    options[#options + 1] = { title = tostring(tokens / 1000) .. 'k', tokens = tokens }
  end
  vim.ui.select(options, { prompt = 'Local context budget', format_item = function(item) return item.title end },
    function(value) if value then done(value.tokens) end end)
end
local function picker()
  if active then notify('Finish or cancel the active turn before changing models', vim.log.levels.WARN); return end
  bridge.ensure(function(err)
    if err then notify(err, vim.log.levels.ERROR); return end
    local catalogue = (bridge.runtime() or {}).models or {}
    if #catalogue == 0 then
      notify('Runtime did not announce models; enter a model ID manually', vim.log.levels.WARN)
      M.manual(); return
    end
    vim.ui.select(catalogue, { prompt = 'Claude model', format_item = function(item)
      return (item.display_name or item.id) .. ' (' .. item.id .. ')'
    end }, function(item)
      if not item then return end
      effort_options(item, function(effort)
        budget_options(function(budget)
          config.model = item.id
          config.effort = effort ~= vim.NIL and effort or nil
          config.context_limit_tokens = budget ~= vim.NIL and budget or nil
          notify('Selected ' .. model.label(config))
        end)
      end)
    end)
  end)
end
function M.manual()
  if active then notify('Finish or cancel the active turn before changing models', vim.log.levels.WARN); return end
  vim.ui.input({ prompt = 'Claude model expression: ', default = config.model }, function(value)
    if not value then return end
    local next_config, err = model.parse(value, config, (bridge.runtime() or {}).models)
    if not next_config then notify(err, vim.log.levels.WARN); return end
    config = next_config
    notify('Selected ' .. model.label(config))
  end)
end
local function modify_system()
  if active then notify('Finish or cancel the active turn before changing the system prompt', vim.log.levels.WARN); return end
  local text, err = current_prompt()
  if not text then notify(err, vim.log.levels.ERROR); return end
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, 'nvim-claude://system-prompt/' .. buf)
  vim.bo[buf].buftype = 'acwrite'; vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'text'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, '\n', { plain = true }))
  vim.api.nvim_create_autocmd('BufWriteCmd', { buffer = buf, callback = function()
    override = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
    vim.bo[buf].modified = false
    notify('System prompt updated for subsequent turns; the runtime prefix cache may change')
  end })
  vim.api.nvim_set_current_buf(buf)
end
local function command(args)
  local words = vim.split(vim.trim(args), '%s+', { trimempty = true })
  local action = words[1]
  if not action or action == '' then
    ui.message('NvClaude', { 'ask [previous], replace, generate, model, model manual',
      'new, clear, save, sticky [on|off], list, info, compact, cancel',
      'system modify|default, watermarks allow|remove|replace, login, result' }, vim.api.nvim_get_current_win())
  elseif action == 'ask' then reserve('ask', false, false, words[2] == 'previous', words[2] ~= 'previous')
  elseif action == 'replace' then reserve('replace', false, false, true)
  elseif action == 'generate' then reserve('generate', false, false, false)
  elseif action == 'model' then if words[2] == 'manual' then M.manual() else picker() end
  elseif action == 'new' or action == 'clear' or action == 'save' or action == 'compact' then session(action)
  elseif action == 'sticky' then session('sticky', { value = words[2] })
  elseif action == 'list' then list()
  elseif action == 'info' then info()
  elseif action == 'cancel' then M.cancel()
  elseif action == 'result' then local view = ui.last_answer(); if view then ui.show(view) else notify('No result yet') end
  elseif action == 'login' then bridge.rpc('login', {}, function(err, result)
    if err then notify(error_message(err), vim.log.levels.ERROR); return end
    if not result or type(result.command) ~= 'table' then
      notify('Runtime did not supply an interactive login command', vim.log.levels.ERROR); return
    end
    vim.cmd('botright new')
    vim.fn.termopen(result.command)
    vim.cmd.startinsert()
  end)
  elseif action == 'system' then
    if words[2] == 'modify' then modify_system()
    elseif words[2] == 'default' then
      if active then notify('Finish or cancel the active turn before changing the system prompt', vim.log.levels.WARN); return end
      override = nil; notify('Restored the shipped system prompt')
    else notify('Use :NvClaude system modify|default', vim.log.levels.WARN) end
  elseif action == 'watermarks' then
    if words[2] == 'allow' or words[2] == 'remove' or words[2] == 'replace' then
      punctuation = words[2]; notify('Punctuation normalization: ' .. punctuation)
    else notify('Use :NvClaude watermarks allow|remove|replace', vim.log.levels.WARN) end
  else notify('Unknown NvClaude action: ' .. action, vim.log.levels.WARN) end
end
local actions = { 'ask', 'replace', 'generate', 'model', 'new', 'clear', 'save',
  'sticky', 'list', 'info', 'compact', 'cancel', 'login', 'result', 'system', 'watermarks' }
local completions = { ask = { 'previous' }, model = { 'manual' },
  sticky = { 'on', 'off' }, system = { 'modify', 'default' },
  watermarks = { 'allow', 'remove', 'replace' } }
local function complete(arg, line)
  local split = vim.split(line, '%s+', { trimempty = true })
  local options
  if #split < 2 or (#split == 2 and line:sub(-1) ~= ' ') then
    options = actions
  else
    options = completions[split[2]] or {}
  end
  return vim.tbl_filter(function(value) return vim.startswith(value, arg) end, options)
end
local function has_mapping(mode, lhs)
  local existing = vim.fn.maparg(lhs, mode, false, true)
  return type(existing) == 'table' and next(existing) ~= nil
end
local function map(mode, lhs, callback, explicit, name)
  if not lhs then return end
  if not explicit and has_mapping(mode, lhs) then return end
  vim.keymap.set(mode, lhs, callback, { desc = 'NvClaude ' .. name, silent = true })
  installed_maps[#installed_maps + 1] = { mode, lhs, name }
end
function M.setup(opts)
  opts = opts or {}
  bridge.python = opts.python
  for _, entry in ipairs(installed_maps) do
    local mapping = vim.fn.maparg(entry[2], entry[1], false, true)
    if type(mapping) == 'table' and mapping.desc == 'NvClaude ' .. entry[3] then
      pcall(vim.keymap.del, entry[1], entry[2])
    end
  end
  installed_maps = {}
  pcall(vim.api.nvim_del_user_command, 'NvClaude')
  vim.api.nvim_create_user_command('NvClaude', function(command_args) command(command_args.args) end,
    { nargs = '*', complete = complete, desc = 'Claude cursor-local editing' })
  if opts.model or opts.effort or opts.context_limit_tokens ~= nil then
    config.model = opts.model or config.model
    config.effort = opts.effort or config.effort
    config.context_limit_tokens = opts.context_limit_tokens or config.context_limit_tokens
  end
  if opts.keys == false then return end
  local user_keys = type(opts.keys) == 'table' and opts.keys or {}
  local handlers = {
    replace = function(selected) reserve('replace', selected, false, true) end,
    replace_short = function(selected) reserve('replace', selected, false, true) end,
    ask = function(selected) reserve('ask', selected, false, false) end,
    generate = function() reserve('generate', false, false, false) end,
    generate_insert = function() reserve('generate', false, true, false) end,
    model = picker, model_manual = M.manual,
    clear = function() session('clear') end, new = function() session('new') end,
    sticky = function() session('sticky') end, save = function() session('save') end,
    info = info, list = list,
  }
  for name, default in pairs(defaults) do
    local key = user_keys[name]
    if key == nil then key = default end
    if type(key) == 'string' and key ~= '' then
      local modes = (name == 'replace' or name == 'replace_short' or name == 'ask') and { 'n', 'x' }
        or { name == 'generate_insert' and 'i' or 'n' }
      for _, mode in ipairs(modes) do
        local selected, handler = mode == 'x', handlers[name]
        map(mode, key, function() handler(selected) end, user_keys[name] ~= nil, name)
      end
    end
  end
end
return M
