local M = {}
local backend = require('nvim-claude.backend')
local targets = require('nvim-claude.targets')
local ui = require('nvim-claude.ui')
local state = { epoch = 0, serial = 0, remembered = {}, punctuation = 'allow', maps = {}, config = { model = 'claude-haiku-5-5', effort = 'low', context_limit_tokens = 100000 } }
local function notify(s, level) vim.notify('nvim-claude: ' .. s, level or vim.log.levels.INFO) end
local punctuation = { ['—'] = '-', ['–'] = '-', ['‘'] = "'", ['’'] = "'", ['“'] = '"', ['”'] = '"', ['…'] = '...', [' '] = ' ' }
local function normalize(s)
  if state.punctuation == 'allow' then return s end
  for char, replacement in pairs(punctuation) do s = s:gsub(char, state.punctuation == 'remove' and '' or replacement) end
  return s
end
local function show(title, value, origin)
  return ui.float(title, vim.split(type(value) == 'string' and value or vim.inspect(value), '\n', { plain = true }), origin or vim.api.nvim_get_current_win())
end
local function request(method, params, cb)
  backend.request(method, params, function(err, result)
    if err then notify(err, vim.log.levels.ERROR); if cb then cb(nil, err) end
    elseif cb then cb(result) end
  end)
end
local function cancel()
  if not state.active then return end
  local old = state.active
  state.active, state.epoch = nil, state.epoch + 1
  targets.highlight(old.target, false)
  old.answer.title(old.operation .. ' · canceled')
  request('cancel', {}, function() end)
end
local function envelope(raw, target)
  local ok, value = pcall(vim.json.decode, raw)
  if not ok or type(value) ~= 'table' then return nil, 'Malformed edit JSON' end
  if value.status == 'needs_input' then
    if type(value.message) ~= 'string' or value.replacements ~= nil then return nil, 'Invalid needs_input envelope' end
    for k in pairs(value) do if k ~= 'status' and k ~= 'message' then return nil, 'Unexpected edit envelope field' end end
    return nil, value.message
  end
  if value.status ~= 'ok' or type(value.replacements) ~= 'table' or not vim.islist(value.replacements) then return nil, 'Invalid edit envelope' end
  for k in pairs(value) do if k ~= 'status' and k ~= 'replacements' then return nil, 'Unexpected edit envelope field' end end
  local expected, out = {}, {}
  for _, s in ipairs(target.segments) do expected[s.id] = s end
  for _, r in ipairs(value.replacements) do
    if type(r) ~= 'table' or type(r.id) ~= 'string' or not expected[r.id] or out[r.id] ~= nil or type(r.text) ~= 'string' then return nil, 'Duplicate, extra, or invalid edit target' end
    for k in pairs(r) do if k ~= 'id' and k ~= 'text' then return nil, 'Unexpected replacement field' end end
    if expected[r.id].block and r.text:find('[\r\n]') then return nil, 'Block replacements must remain on their rows' end
    if r.text:find('\0', 1, true) then return nil, 'NUL bytes cannot be represented as literal buffer text' end
    out[r.id] = normalize(r.text)
  end
  for id in pairs(expected) do if out[id] == nil then return nil, 'Missing edit target' end end
  return out
end
local function dispatch(operation, target, origin, cursor)
  if state.prompt and vim.api.nvim_win_is_valid(state.prompt.win) then
    vim.api.nvim_set_current_win(state.prompt.win); return
  end
  targets.highlight(target, true)
  state.prompt = ui.prompt(operation .. ' · ' .. state.config.model, origin, cursor, function(instruction, prompt)
    if state.active then notify('Conversation is busy; this draft has been retained.'); return end
    if not instruction:match('%S') then notify('Enter an instruction.'); return end
    if target and not targets.valid(target) then notify('The captured target changed; select it again.', vim.log.levels.WARN); return end
    local params = { operation = operation, instruction = instruction, epoch = state.epoch }
    if target then
      local buf = target.buf
      params.document = { id = 'buffer-' .. buf, filetype = vim.bo[buf].filetype, text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n'), revision = tostring(vim.api.nvim_buf_get_changedtick(buf)) }
      params.targets = targets.payload(target)
    end
    state.serial = state.serial + 1
    params.request_id = tostring(vim.fn.getpid()) .. '-' .. state.serial
    local active = { request_id = params.request_id, epoch = state.epoch, target = target, operation = operation, raw = '', origin = origin }
    state.active = active
    vim.cmd('stopinsert')
    prompt.close(); state.prompt = nil
    targets.highlight(target, true)
    active.answer = show(operation .. ' · preparing session', '', origin)
    if operation ~= 'ask' and vim.api.nvim_win_is_valid(origin) then vim.api.nvim_set_current_win(origin) end
    backend.request('turn', params, function(err, result)
      if state.active ~= active or active.epoch ~= state.epoch then return end
      state.active = nil
      targets.highlight(target, false)
      if err then
        active.answer.title(operation .. ' · failed')
        active.answer.set((active.raw ~= '' and normalize(active.raw) .. '\n\n' or '') .. err)
        notify(err, vim.log.levels.ERROR)
        return
      end
      if type(result) ~= 'table' or type(result.text) ~= 'string' then
        active.answer.title(operation .. ' · invalid bridge response'); return
      end
      if result.info and result.info.config then state.config = result.info.config end
      if operation == 'ask' then
        active.answer.set(normalize(result.text)); active.answer.title('ask · complete'); return
      end
      local replacements, problem = envelope(result.text, target)
      if replacements then
        local remembered, apply_error = targets.apply(target, replacements)
        if remembered then
          state.remembered[target.buf] = remembered
          active.answer.set('Applied ' .. operation .. ' to the captured target.\n\n' .. table.concat(vim.tbl_values(replacements), '\n'))
          active.answer.title(operation .. ' · complete')
          if not vim.api.nvim_win_is_valid(active.answer.win) then notify(operation .. ' complete') end
          return
        end
        problem = apply_error
      end
      active.answer.title(operation .. ' · not applied')
      active.answer.set(problem .. '\n\nRaw result:\n' .. result.text)
      if not vim.api.nvim_win_is_valid(active.answer.win) then show(operation .. ' · not applied', problem .. '\n\n' .. result.text, origin) end
    end, function() return state.active == active and state.epoch == active.epoch end)
  end, function() targets.highlight(target, false); state.prompt = nil end)
end
backend.on_event = function(method, event)
  local a = state.active
  if not a or event.request_id ~= a.request_id or event.epoch ~= a.epoch then return end
  if method == 'text' and type(event.text) == 'string' then
    a.raw = a.raw .. event.text
    a.answer.set(normalize(a.raw))
  elseif method == 'status' then a.answer.title(a.operation .. ' · ' .. tostring(event.message)) end
end
-- Actions capture source ownership before any prompt or response window is opened.
function M.invoke(operation, selected, previous)
  local buf, origin = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  local cursor = vim.api.nvim_win_get_cursor(origin)
  local target
  if selected then target = targets.visual(buf, selected == 'command')
  elseif operation == 'generate' then target = targets.generate(buf, cursor)
  elseif operation == 'replace' then target = state.remembered[buf]
  elseif previous or (previous == nil and state.chain and state.chain.buf == buf) then target = state.chain and state.chain.target end
  if operation == 'replace' or previous then
    if not targets.valid(target) then notify('A valid selection in this buffer is needed.'); return end
  elseif target and not targets.valid(target) then target = nil end
  if target and operation == 'ask' then state.chain = { buf = buf, target = target }
  else state.chain = nil end
  if selected and operation == 'replace' then state.remembered[buf] = target end
  dispatch(operation, target, origin, cursor)
end
local function configure(params)
  if state.active then notify('Wait for the active turn or cancel it before changing model settings.'); return end
  request('configure', params, function(config) if config then state.config = config; notify('Model configuration: ' .. vim.inspect(config)) end end)
end
local function manual()
  vim.ui.input({ prompt = 'Model expression: ', default = state.config.model }, function(value) if value and value ~= '' then configure({ expression = value }) end end)
end
local function model_picker()
  request('models', {}, function(result)
    if not result then return end
    local models = result.models or {}
    if #models == 0 then notify('Runtime model discovery is unavailable; use model manual.'); return end
    vim.ui.select(models, { prompt = 'Model', format_item = function(m) return type(m) == 'table' and (m.display_name or m.value) or m end }, function(model)
      if not model then return end
      local value = type(model) == 'table' and model.value or model
      local efforts = type(model) == 'table' and model.supported_efforts or nil
      local function budget(effort)
        local choices = { { label = 'model default', value = vim.NIL } }
        for _, n in ipairs(result.presets or {}) do table.insert(choices, { label = tostring(n / 1000) .. 'k', value = n }) end
        vim.ui.select(choices, { prompt = 'Context budget (cannot enlarge physical context)', format_item = function(c) return c.label end }, function(limit)
          if limit then configure({ model = value, effort = effort or vim.NIL, context_limit_tokens = limit.value }) end
        end)
      end
      if efforts and #efforts > 0 then vim.ui.select(efforts, { prompt = 'Supported effort' }, function(e) if e then budget(e) end end)
      else budget(nil) end
    end)
  end)
end
local function session(action, arg)
  if action == 'new' or action == 'clear' or action == 'resume' then cancel(); state.epoch = state.epoch + 1; state.chain = nil end
  local params = { action = action }
  if action == 'resume' then params.id = arg end
  if action == 'sticky' and arg then
    if arg ~= 'on' and arg ~= 'off' then notify('Use sticky [on|off]'); return end
    params.on = arg == 'on'
  end
  request('session', params, function(result)
    if not result then return end
    if action == 'list' then
      local items = result.items or result
      vim.ui.select(items, { prompt = 'Saved conversations', format_item = function(item) return (item.title or '') .. ' [' .. item.id .. ']' end }, function(item)
        if item then session('resume', item.id) end
      end)
    else notify(vim.inspect(result)) end
  end)
end
local function system(action)
  if state.active then notify('System prompt changes must happen between turns.'); return end
  if action == 'default' then request('system', { reset = true }, function(result) if result then state.system = nil; notify('Default system prompt restored') end end); return end
  if action ~= 'modify' then notify('Use system modify or system default'); return end
  local lines = state.system and vim.split(state.system, '\n', { plain = true }) or vim.fn.readfile(backend.root .. '/resources/system.txt')
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].filetype = 'acwrite', 'hide', 'text'
  vim.api.nvim_buf_set_name(buf, 'nvim-claude://system/' .. buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_create_autocmd('BufWriteCmd', { buffer = buf, callback = function()
    if state.active then notify('Wait for the active turn before saving the system prompt.'); return end
    local value = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
    request('system', { text = value }, function(result)
      if result then state.system = value; vim.bo[buf].modified = false; notify('System prompt updated for subsequent turns') end
    end)
  end })
end
local commands = { 'ask', 'replace', 'generate', 'model', 'clear', 'new', 'sticky', 'save', 'compact', 'info', 'list', 'resume', 'cancel', 'watermarks', 'system', 'login', 'update' }
function M.command(args, range)
  local action, arg = args[1] or 'ask', args[2]
  if action == 'ask' then M.invoke('ask', range and 'command' or false, arg == 'previous')
  elseif action == 'replace' then M.invoke(action, range and 'command' or false)
  elseif action == 'generate' then M.invoke(action)
  elseif action == 'cancel' then cancel()
  elseif action == 'model' then if arg == 'manual' then manual() elseif arg then configure({ expression = table.concat(args, ' ', 2) }) else model_picker() end
  elseif action == 'info' then request('info', {}, function(result) if result then show('Conversation info', result) end end)
  elseif action == 'watermarks' then
    if arg == 'allow' or arg == 'replace' or arg == 'remove' then state.punctuation = arg; notify('Punctuation normalization: ' .. arg) else notify('Use watermarks allow|replace|remove') end
  elseif action == 'system' then system(arg)
  elseif action == 'login' then request('login', {}, function(result)
    if not result or type(result.argv) ~= 'table' then return end
    vim.cmd('botright new'); vim.fn.termopen(result.argv); vim.cmd('startinsert')
  end)
  elseif action == 'update' then
    if state.active then notify('Cancel or finish the active request before updating.'); return end
    backend.update(function(err) notify(err or 'SDK update complete; bridge will restart on next use', err and vim.log.levels.ERROR or nil) end)
  elseif vim.tbl_contains({ 'clear', 'new', 'sticky', 'save', 'compact', 'list', 'resume' }, action) then session(action, arg)
  else notify('Unknown command: ' .. action) end
end
local defaults = {
  replace = { '<leader>cc', { 'n', 'x' } }, replace_short = { '<leader>c', { 'n', 'x' } },
  ask = { '<leader>ca', { 'n', 'x' } }, generate = { '<leader>ci', { 'n' } }, generate_insert = { false, { 'i' } },
  model = { '<leader>cm', { 'n' } }, model_manual = { '<leader>cM', { 'n' } }, clear = { '<leader>cC', { 'n' } },
  new = { '<leader>cn', { 'n' } }, sticky = { '<leader>cS', { 'n' } }, save = { '<leader>cs', { 'n' } },
  info = { '<leader>cx', { 'n' } }, list = { '<leader>cl', { 'n' } },
}
function M.setup(opts)
  opts = opts or {}
  backend.setup(opts)
  for _, key in ipairs({ 'model', 'effort', 'context_limit_tokens' }) do if opts[key] ~= nil then state.config[key] = opts[key] end end
  for _, mapping in ipairs(state.maps) do
    local existing = vim.fn.maparg(mapping.lhs, mapping.mode, false, true)
    if existing.callback == mapping.callback then pcall(vim.keymap.del, mapping.mode, mapping.lhs) end
  end
  state.maps = {}
  if opts.keys ~= false then
    for action, spec in pairs(defaults) do
      local explicit = type(opts.keys) == 'table' and opts.keys[action] ~= nil
      local lhs = explicit and opts.keys[action] or spec[1]
      if explicit and opts.keys[action] == false then lhs = false end
      if type(lhs) == 'string' then
        for _, mode in ipairs(spec[2]) do
          if explicit or next(vim.fn.maparg(lhs, mode, false, true)) == nil then
            local callback = function()
              if action == 'replace' or action == 'replace_short' then M.invoke('replace', mode == 'x')
              elseif action == 'ask' then M.invoke('ask', mode == 'x')
              elseif action == 'generate' or action == 'generate_insert' then M.invoke('generate')
              elseif action == 'model_manual' then manual()
              else M.command({ action }) end
            end
            vim.keymap.set(mode, lhs, callback, { silent = true, desc = 'nvim-claude: ' .. action })
            table.insert(state.maps, { lhs = lhs, mode = mode, callback = callback })
          end
        end
      end
    end
  end
  pcall(vim.api.nvim_del_user_command, 'NvClaude')
  vim.api.nvim_create_user_command('NvClaude', function(cmd) M.command(cmd.fargs, cmd.range > 0) end, {
    nargs = '*', range = true, complete = function(lead, line)
      local words = vim.split(line, '%s+', { trimempty = true })
      local choices = commands
      if #words > 2 or (#words == 2 and line:sub(-1) == ' ') then
        local sub = { ask = { 'previous' }, model = { 'manual' }, sticky = { 'on', 'off' }, watermarks = { 'allow', 'replace', 'remove' }, system = { 'modify', 'default' } }
        choices = sub[words[2]] or {}
      end
      return vim.tbl_filter(function(s) return s:sub(1, #lead) == lead end, choices)
    end,
  })
  local group = vim.api.nvim_create_augroup('NvClaudeLifecycle', { clear = true })
  vim.api.nvim_create_autocmd('VimLeavePre', { group = group, callback = backend.stop })
  vim.api.nvim_create_autocmd('BufEnter', { group = group, callback = function(event)
    if state.chain and state.chain.buf ~= event.buf and vim.bo[event.buf].buftype == '' then state.chain = nil end
  end })
end
return M
