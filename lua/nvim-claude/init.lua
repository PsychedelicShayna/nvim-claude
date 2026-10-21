local M = {}
local api = vim.api
local bridge = require('nvim-claude.bridge')
local targets = require('nvim-claude.targets')
local state = {epoch = 0, remembered = {}, mappings = {}, config = {
  model = 'claude-haiku-5-5', effort = 'low', context_limit_tokens = 100000,
}}
local defaults = {
  replace = {'<leader>cc', {'n', 'x'}}, replace_short = {'<leader>c', {'n', 'x'}},
  ask = {'<leader>ca', {'n', 'x'}}, generate = {'<leader>ci', {'n'}},
  generate_insert = {false, {'i'}}, model = {'<leader>cm', {'n'}},
  model_manual = {'<leader>cM', {'n'}}, clear = {'<leader>cC', {'n'}},
  new = {'<leader>cn', {'n'}}, sticky = {'<leader>cS', {'n'}},
  save = {'<leader>cs', {'n'}}, info = {'<leader>cx', {'n'}}, list = {'<leader>cl', {'n'}},
}
local commands = {'ask', 'replace', 'generate', 'model', 'model_manual', 'clear', 'new',
  'sticky', 'save', 'info', 'list', 'resume', 'compact', 'cancel', 'system', 'watermarks', 'login', 'update'}
local function notify(text, level) vim.notify('nvim-claude: ' .. text, level or vim.log.levels.INFO) end
local function focus(win) if win and api.nvim_win_is_valid(win) then api.nvim_set_current_win(win) end end
local function close(float)
  if float and api.nvim_win_is_valid(float.win) then api.nvim_win_close(float.win, true) end
  if float then focus(float.origin) end
end
local function float(title, origin, prompt)
  local width = math.max(1, math.min(prompt and 64 or 90, vim.o.columns - 4))
  local height = math.max(1, math.min(prompt and 3 or 16, vim.o.lines - 5))
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].filetype = prompt and 'text' or 'markdown'
  local config = {relative = 'editor', row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)), width = width, height = height,
    style = 'minimal', border = 'rounded', title = ' ' .. title .. ' ', title_pos = 'left'}
  if prompt and origin and api.nvim_win_is_valid(origin) then
    local cursor = api.nvim_win_get_cursor(origin)
    local screen = vim.fn.screenpos(origin, cursor[1], cursor[2] + 1)
    config.row = math.max(0, math.min(vim.o.lines - height - 4, screen.row))
    config.col = math.max(0, math.min(vim.o.columns - width - 2, screen.col - 1))
  end
  local win = api.nvim_open_win(buf, true, config)
  vim.wo[win].wrap = true
  local result = {buf = buf, win = win, origin = origin}
  for _, key in ipairs({'q', '<Esc>'}) do
    vim.keymap.set('n', key, function() close(result) end, {buffer = buf, nowait = true})
  end
  return result
end
local function put(view, text)
  if not view or not api.nvim_buf_is_valid(view.buf) then return end
  api.nvim_buf_set_lines(view.buf, 0, -1, false, vim.split(text, '\n', {plain = true}))
end
local function show(text, title, origin)
  local view = float(title or 'Claude', origin or api.nvim_get_current_win())
  put(view, text)
  return view
end
local function info_result(result, err)
  if err then notify(err, vim.log.levels.ERROR); return end
  if result.config then state.config = result.config end
  show(vim.inspect(result), 'Claude info')
end

local function event(kind, params)
  local request = state.active
  if not request or params.epoch ~= request.epoch then return end
  if kind == 'partial' then put(request.view, params.text)
  elseif kind == 'status' then
    if api.nvim_win_is_valid(request.view.win) then
      api.nvim_win_set_config(request.view.win, {title = ' ' .. request.operation .. ' · ' .. params.text .. ' '})
    end
    notify(request.operation .. ': ' .. params.text)
  end
end

function M.open(operation, mode)
  if state.prompt and api.nvim_win_is_valid(state.prompt.win) then focus(state.prompt.win); return end
  local visual = mode == 'visual' or vim.fn.mode():match('^[vV\22]') ~= nil
  local buf, origin = api.nvim_get_current_buf(), api.nvim_get_current_win()
  local target
  if visual then
    local ok, value = pcall(targets.capture, operation, true)
    if not ok then notify(value, vim.log.levels.ERROR); return end
    target = value
  elseif operation == 'generate' then
    target = targets.capture(operation, false)
  elseif operation == 'replace' then
    target = state.remembered[buf]
  elseif operation == 'ask' and mode ~= 'general' then
    if state.last_action == 'selected-ask' and state.ask_target and state.ask_target.buf == buf then
      target = state.ask_target
      if not targets.valid(target) then target = nil end
    end
    if mode == 'previous' and not target then notify('No valid selected-ask target in this buffer'); return end
  end
  if operation == 'replace' and not target then notify('Select text before replacing'); return end
  if target then
    local valid, reason = targets.valid(target)
    if not valid then notify(reason); return end
  end
  if operation == 'ask' and target then
    state.last_action, state.ask_target = 'selected-ask', target
  else
    state.last_action, state.ask_target = operation, nil
  end
  if operation == 'replace' then state.remembered[buf] = target end
  local prompt = float(operation .. ' · ' .. state.config.model, origin, true)
  state.prompt = prompt
  vim.keymap.del('n', 'q', {buffer = prompt.buf})
  local function dismiss()
    close(prompt)
    state.prompt = nil
  end
  vim.keymap.set('n', '<Esc>', dismiss, {buffer = prompt.buf, nowait = true})
  local function submit()
    if state.active then notify('Conversation busy; draft retained'); return end
    local instruction = table.concat(api.nvim_buf_get_lines(prompt.buf, 0, -1, false), '\n')
    if not instruction:match('%S') then notify('Enter an instruction'); return end
    local params = {operation = operation, instruction = instruction}
    if target then
      local ok, value = pcall(targets.dispatch, target)
      if not ok then notify(value, vim.log.levels.ERROR); return end
      params.targets, params.block = value, target.block
      params.document = {id = 'buffer-' .. target.buf, filetype = vim.bo[target.buf].filetype,
        revision = tostring(api.nvim_buf_get_changedtick(target.buf)),
        text = table.concat(api.nvim_buf_get_lines(target.buf, 0, -1, false), '\n')}
    end
    vim.cmd.stopinsert()
    dismiss()
    state.epoch = state.epoch + 1
    params.epoch = state.epoch
    local view = show('', operation .. ' · preparing', origin)
    focus(origin)
    local request = {epoch = state.epoch, operation = operation, target = target, view = view}
    state.active = request
    bridge.request('submit', params, function(result, err)
      if request.epoch ~= state.epoch then return end
      state.active = nil
      if err then put(view, err); notify(err, vim.log.levels.ERROR); return end
      if result.text then put(view, result.text) end
      if result.error then notify(result.error, vim.log.levels.ERROR); return end
      if operation == 'ask' then return end
      if result.status == 'needs_input' then put(view, result.message); return end
      local ok, reason = targets.apply(target, result.replacements)
      if not ok then
        put(view, reason .. '\n\n' .. vim.inspect(result.replacements))
        notify('Result retained: ' .. reason, vim.log.levels.WARN)
      else
        state.remembered[target.buf] = target
        put(view, table.concat(vim.tbl_map(function(item) return item.text end, result.replacements), '\n'))
        if api.nvim_win_is_valid(view.win) then api.nvim_win_close(view.win, true) end
        notify('Applied ' .. operation .. '; one undo reverses it')
      end
    end)
  end
  vim.keymap.set({'n', 'i'}, '<C-s>', submit, {buffer = prompt.buf})
  vim.keymap.set('n', '<CR>', submit, {buffer = prompt.buf})
  api.nvim_create_autocmd({'TextChangedI', 'TextChanged'}, {buffer = prompt.buf, callback = function()
    if api.nvim_win_is_valid(prompt.win) then
      api.nvim_win_set_config(prompt.win, {height = math.max(1, math.min(10, vim.o.lines - 5, api.nvim_buf_line_count(prompt.buf)))})
    end
  end})
  vim.cmd.startinsert()
end

local function configure(candidate)
  bridge.request('configure', candidate, function(result, err)
    if err then notify(err, vim.log.levels.ERROR); return end
    state.config = result.config
    notify('Model: ' .. state.config.model .. ' · budget ' .. tostring(state.config.context_limit_tokens))
  end)
end

local function pick_model()
  bridge.request('models', {}, function(result, err)
    if err then notify(err, vim.log.levels.ERROR); return end
    if not result.models or #result.models == 0 then notify('Runtime supplied no models; use :NvClaude model_manual'); return end
    vim.ui.select(result.models, {prompt = 'Claude model', format_item = function(m) return m.displayName .. ' [' .. m.value .. ']' end}, function(model)
      if not model then return end
      local function budget(effort)
        local choices = {'model default'}
        for _, value in ipairs(result.presets) do choices[#choices + 1] = value end
        vim.ui.select(choices, {prompt = 'Prompt budget', format_item = tostring}, function(limit)
          if limit == nil then return end
          configure({model = model.value, effort = effort or vim.NIL,
            context_limit_tokens = limit == 'model default' and vim.NIL or limit})
        end)
      end
      if model.supportedEffortLevels and #model.supportedEffortLevels > 0 then
        vim.ui.select(model.supportedEffortLevels, {prompt = 'Effort'}, function(effort) if effort then budget(effort) end end)
      else budget(nil) end
    end)
  end)
end

function M.command(command, args)
  args = args or {}
  if command == 'ask' then M.open('ask', args[1] == 'previous' and 'previous' or 'general')
  elseif command == 'replace' or command == 'generate' then M.open(command)
  elseif command == 'cancel' then
    state.epoch = state.epoch + 1
    if state.active then put(state.active.view, 'Cancelled; source unchanged') end
    state.active = nil
    bridge.request('cancel', {}, function() notify('Cancelled') end)
  elseif command == 'model' then pick_model()
  elseif command == 'model_manual' then
    vim.ui.input({prompt = 'Model expression: ', default = state.config.model}, function(value)
      if value and value ~= '' then configure({expression = value}) end
    end)
  elseif command == 'list' then
    bridge.request('list', {}, function(result, err)
      if err then notify(err, vim.log.levels.ERROR); return end
      vim.ui.select(result, {prompt = 'Saved conversations', format_item = function(row) return row.title .. ' [' .. row.id .. ']' end}, function(row)
        if row then M.command('resume', {row.id}) end
      end)
    end)
  elseif command == 'system' then
    if args[1] == 'default' then bridge.request('system', {}, function(result, err)
      if err then notify(err, vim.log.levels.ERROR) else state.system = result.system; notify(result.note) end
    end)
    elseif args[1] == 'modify' then
      local path = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)))) .. '/python/system.txt'
      local view = show(state.system or table.concat(vim.fn.readfile(path), '\n'), 'System prompt · :write to apply')
      vim.bo[view.buf].buftype = 'acwrite'
      api.nvim_buf_set_name(view.buf, 'nvim-claude-system-' .. view.buf)
      api.nvim_create_autocmd('BufWriteCmd', {buffer = view.buf, callback = function()
        if state.active then notify('Wait for the active request before changing the prompt'); return end
        local text = table.concat(api.nvim_buf_get_lines(view.buf, 0, -1, false), '\n')
        bridge.request('system', {text = text}, function(result, err)
          if err then notify(err, vim.log.levels.ERROR); return end
          state.system = result.system
          vim.bo[view.buf].modified = false
          notify(result.note)
        end)
      end})
    else notify('Use system modify or system default') end
  elseif command == 'watermarks' then bridge.request('watermarks', {policy = args[1]})
  elseif command == 'login' then
    bridge.request('login', {}, function(result, err)
      if err then notify(err, vim.log.levels.ERROR); return end
      vim.cmd.new()
      vim.fn.jobstart(result.argv, {term = true})
      vim.cmd.startinsert()
    end)
  elseif command == 'update' then
    if state.active then notify('Cancel or finish the request before updating'); return end
    bridge.stop()
    bridge.ensure(true, function() notify('SDK updated. Restart Neovim to use the new runtime.') end)
  elseif command == 'new' or command == 'clear' or command == 'resume' then
    state.epoch = state.epoch + 1
    state.active, state.ask_target, state.last_action = nil, nil, nil
    bridge.request(command, {id = args[1]}, info_result)
  elseif command == 'sticky' then
    local params = {}
    if args[1] then params.enabled = args[1] == 'on' end
    bridge.request(command, params, info_result)
  elseif command == 'save' or command == 'info' or command == 'compact' then
    bridge.request(command, {}, info_result)
  else notify('Unknown command: ' .. tostring(command), vim.log.levels.ERROR) end
end

function M.setup(opts)
  opts = opts or {}
  if vim.fn.has('nvim-0.11') == 0 then error('nvim-claude requires Neovim 0.11+') end
  state.config = vim.tbl_extend('force', state.config, opts.model and {model = opts.model} or {},
    opts.effort and {effort = opts.effort} or {}, opts.context_limit_tokens and {context_limit_tokens = opts.context_limit_tokens} or {})
  bridge.setup({python = opts.python or 'python3',
    data_dir = opts.data_dir or vim.fn.stdpath('data') .. '/nvim-claude',
    state_dir = opts.state_dir or vim.fn.stdpath('state') .. '/nvim-claude', config = state.config}, event)
  pcall(api.nvim_del_user_command, 'NvClaude')
  api.nvim_create_user_command('NvClaude', function(cmd)
    local args = vim.deepcopy(cmd.fargs)
    local command = table.remove(args, 1) or 'ask'
    M.command(command, args)
  end, {nargs = '*', complete = function(lead)
    return vim.tbl_filter(function(value) return value:sub(1, #lead) == lead end, commands)
  end})
  for _, mapping in ipairs(state.mappings) do
    local existing = vim.fn.maparg(mapping.key, mapping.mode, false, true)
    if existing.desc == mapping.desc then pcall(vim.keymap.del, mapping.mode, mapping.key) end
  end
  state.mappings = {}
  if opts.keys ~= false then
    for name, definition in pairs(defaults) do
      local explicit = opts.keys and opts.keys[name] ~= nil
      local key = explicit and opts.keys[name] or definition[1]
      if explicit and opts.keys[name] == false then key = false end
      if key then
        for _, mode in ipairs(definition[2]) do
          if explicit or vim.fn.maparg(key, mode) == '' then
            local action = name == 'replace_short' and 'replace' or name == 'generate_insert' and 'generate' or name
            local desc = 'nvim-claude ' .. name
            vim.keymap.set(mode, key, function()
              if action == 'ask' or action == 'replace' or action == 'generate' then M.open(action, mode == 'x' and 'visual' or nil)
              else M.command(action) end
            end, {desc = desc})
            state.mappings[#state.mappings + 1] = {mode = mode, key = key, desc = desc}
          end
        end
      end
    end
  end
  local group = api.nvim_create_augroup('nvim-claude', {clear = true})
  api.nvim_create_autocmd('VimLeavePre', {group = group, callback = bridge.stop})
  api.nvim_create_autocmd('BufEnter', {group = group, callback = function(args)
    if state.ask_target and args.buf ~= state.ask_target.buf and vim.bo[args.buf].buftype == '' then
      state.ask_target, state.last_action = nil, nil
    end
  end})
end

return M
