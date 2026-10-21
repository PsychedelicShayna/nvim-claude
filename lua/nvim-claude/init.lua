local M = {}
local api = vim.api
local bridge = require('nvim-claude.bridge')
local targets = require('nvim-claude.targets')
local ui = require('nvim-claude.ui')
local state = { epoch = 0, serial = 0, mappings = {}, remembered = {}, prompts = {}, last_action = nil }
local commands = { 'ask', 'replace', 'generate', 'model', 'new', 'clear', 'save', 'sticky', 'info', 'list', 'resume', 'compact', 'cancel', 'watermarks', 'system', 'login', 'setup', 'update', 'result' }
local defaults = {
  replace = { '<leader>cc', { 'n', 'x' } }, replace_short = { '<leader>c', { 'n', 'x' } },
  ask = { '<leader>ca', { 'n', 'x' } }, generate = { '<leader>ci', { 'n' } },
  generate_insert = { false, { 'i' } }, model = { '<leader>cm', { 'n' } },
  model_manual = { '<leader>cM', { 'n' } }, clear = { '<leader>cC', { 'n' } },
  new = { '<leader>cn', { 'n' } }, sticky = { '<leader>cS', { 'n' } },
  save = { '<leader>cs', { 'n' } }, info = { '<leader>cx', { 'n' } }, list = { '<leader>cl', { 'n' } },
}
local function notify(text, error) vim.notify('NvClaude: ' .. text, error and vim.log.levels.ERROR or vim.log.levels.INFO) end
local function configuration()
  return bridge.info and bridge.info.config or bridge.config
end
local function response(result, err)
  if err then notify(err, true); return end
  if result and result.config and bridge.info then bridge.info.config = result.config end
  if result and result.message then notify(result.message) end
end

function M.cancel()
  state.epoch = state.epoch + 1
  if not state.active and bridge.state ~= 'ready' then return end
  if state.active then state.active.cancelled = true end
  bridge.request('cancel', {}, response)
end

local function dispose_unused(target)
  if target and state.remembered[target.buf] ~= target and not state.prompts[target]
    and (not state.active or state.active.target ~= target) then targets.dispose(target) end
end

local function remember(target, action)
  local old = state.remembered[target.buf]
  state.remembered[target.buf] = target
  if old ~= target then dispose_unused(old) end
  state.last_action = { action = action, buf = target.buf, target = target }
end

function M.invoke(operation, visual, previous)
  local buf = api.nvim_get_current_buf()
  local origin = api.nvim_get_current_win()
  local target
  if operation == 'generate' then
    target = targets.capture(operation, false)
    state.last_action = { action = 'generate', buf = buf }
  elseif visual then
    target = targets.capture(operation, true)
    remember(target, operation == 'ask' and 'selected-ask' or 'replace')
  elseif operation == 'replace' then
    target = state.remembered[buf]
    if not targets.valid(target) then notify('Select text before replacement', true); return end
    state.last_action = { action = 'replace', buf = buf }
  elseif previous then
    local last = state.last_action
    target = last and last.action == 'selected-ask' and last.buf == buf and last.target or nil
    if not targets.valid(target) then notify('No valid selected-ask target in this buffer', true); return end
  else
    state.last_action = { action = 'ask', buf = buf }
  end
  local model = configuration().model
  if target then state.prompts[target] = (state.prompts[target] or 0) + 1 end
  local function release_prompt()
    if target then
      local count = (state.prompts[target] or 1) - 1
      state.prompts[target] = count > 0 and count or nil
      dispose_unused(target)
    end
  end
  ui.prompt(operation .. ' · ' .. model, origin, function(instruction)
    if state.active then notify('Conversation is busy; your draft is retained'); return false end
    local selected
    if target then
      local err
      selected, err = targets.payload(target)
      if not selected then notify(err, true); return false end
    end
    state.serial = state.serial + 1
    local request = { request = state.serial, epoch = state.epoch, operation = operation, instruction = instruction }
    if target then
      request.targets, request.block = selected, target.block or false
      request.document = { id = 'buffer-' .. target.buf, filetype = vim.bo[target.buf].filetype,
        revision = 'r' .. api.nvim_buf_get_changedtick(target.buf),
        text = table.concat(api.nvim_buf_get_lines(target.buf, 0, -1, false), '\n') .. (vim.bo[target.buf].endofline and '\n' or '') }
    end
    local view = ui.result(operation .. ' · preparing', origin)
    view.update('Preparing request…')
    state.result = view
    local active = { id = request.request, epoch = request.epoch, view = view, target = target }
    state.active = active
    bridge.request('turn', request, function(result, err)
      view.finish()
      if state.active == active then state.active = nil end
      vim.schedule(function() dispose_unused(target) end)
      if err then view.update('Request failed. No edit applied.\n\n' .. err .. '\n\n' .. (active.partial or '')); view.title(operation .. ' · failed'); return end
      if active.cancelled or state.epoch ~= active.epoch then
        view.update('Cancelled or superseded; no edit applied.\n\n' .. (result.raw or result.text or ''))
        return
      end
      if operation == 'ask' then view.update(result.text); view.title('ask · complete'); return end
      if result.status ~= 'ok' then
        view.update((result.message or 'Invalid edit response') .. '\n\n' .. (result.raw or ''))
        view.title(operation .. ' · not applied'); return
      end
      local ok, message = targets.apply(target, result.replacements)
      if ok then
        remember(target, operation)
        view.update(message)
        view.title(operation .. ' · complete')
      else
        view.update(message .. '\n\n' .. result.raw)
        view.title(operation .. ' · result retained')
      end
    end)
    release_prompt()
    return true
  end, release_prompt)
end

local function configure(config)
  bridge.request('configure', { config = config }, response)
end

function M.model(manual)
  if manual then
    vim.ui.input({ prompt = 'Claude model expression: ', default = configuration().model }, function(value)
      if value then bridge.request('configure', { expression = value }, response) end
    end)
    return
  end
  bridge.request('models', {}, function(result, err)
    if err then notify(err, true); return end
    if #result.models == 0 then notify('Runtime model discovery unavailable; use :NvClaude model manual'); return end
    vim.ui.select(result.models, { prompt = 'Claude model', format_item = function(item) return item.displayName .. ' · ' .. item.value end }, function(model)
      if not model then return end
      local function budget(effort)
        local choices = { 'model default' }
        for _, value in ipairs(result.presets) do choices[#choices + 1] = value end
        vim.ui.select(choices, { prompt = 'Local prompt budget', format_item = tostring }, function(value)
          if not value then return end
          configure({ model = model.value, effort = effort or vim.NIL, context_limit_tokens = type(value) == 'number' and value or vim.NIL })
        end)
      end
      local efforts = model.supportedEffortLevels or {}
      if model.supportsEffort and #efforts > 0 then
        vim.ui.select(efforts, { prompt = 'Effort' }, function(effort) if effort then budget(effort) end end)
      else budget(nil) end
    end)
  end)
end

local function system_modify()
  local text = state.system or table.concat(vim.fn.readfile(bridge.resource()), '\n')
  local buf = api.nvim_create_buf(false, true)
  vim.cmd('botright split')
  api.nvim_win_set_buf(0, buf)
  api.nvim_buf_set_name(buf, 'NvClaude-system-' .. buf)
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].bufhidden = 'wipe'
  api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, '\n', { plain = true }))
  vim.bo[buf].modified = false
  api.nvim_create_autocmd('BufWriteCmd', { buffer = buf, callback = function()
    if state.active then notify('Wait for the current turn or cancel before changing the system prompt', true); return end
    local edited = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
    bridge.request('system', { text = edited }, function(result, err)
      if not err then state.system = edited; if api.nvim_buf_is_valid(buf) then vim.bo[buf].modified = false end end
      response(result, err)
    end)
  end })
end

function M.command(args)
  local words = vim.split(args or '', '%s+', { trimempty = true })
  local name = words[1] or 'ask'
  if name == 'ask' then M.invoke('ask', false, words[2] == 'previous')
  elseif name == 'replace' or name == 'generate' then M.invoke(name, false)
  elseif name == 'cancel' then M.cancel()
  elseif name == 'model' then M.model(words[2] == 'manual')
  elseif name == 'info' then
    local view = ui.result('Claude information', api.nvim_get_current_win())
    bridge.request('info', {}, function(result, err) view.update(err or vim.inspect(result)); view.focus() end)
  elseif name == 'list' then
    bridge.request('list', {}, function(result, err)
      if err then notify(err, true); return end
      vim.ui.select(result, { prompt = 'Saved Claude conversations', format_item = function(item)
        return os.date('%y:%m:%d:%H:%M:%S', item.created) .. ' - ' .. item.first_prompt:gsub('\n', ' '):sub(1, 80) .. ' [' .. item.id:sub(1, 8) .. ']'
      end }, function(item) if item then M.command('resume ' .. item.id) end end)
    end)
  elseif name == 'new' or name == 'clear' or name == 'resume' then
    M.cancel()
    state.last_action = nil
    bridge.request(name, name == 'resume' and { id = words[2] } or {}, response)
  elseif name == 'save' or name == 'compact' then
    if state.active then notify('Wait for the active turn before ' .. name, true); return end
    if name == 'save' then bridge.request(name, {}, response); return end
    state.serial = state.serial + 1
    local view = ui.result('Claude · compacting', api.nvim_get_current_win())
    state.result = view
    local active = { id = state.serial, epoch = state.epoch, view = view }
    state.active = active
    bridge.request('compact', { request = active.id, epoch = active.epoch }, function(result, err)
      if state.active == active then state.active = nil end
      view.finish()
      view.update(err or result.message)
      view.title(err and 'compaction · failed' or 'compaction · complete')
    end)
  elseif name == 'sticky' then
    if words[2] and words[2] ~= 'on' and words[2] ~= 'off' then notify('Use sticky on or off', true); return end
    bridge.request('sticky', words[2] and { enabled = words[2] == 'on' } or {}, response)
  elseif name == 'watermarks' then bridge.request(name, { mode = words[2] or 'allow' }, response)
  elseif name == 'system' then
    if words[2] == 'modify' then system_modify()
    elseif words[2] == 'default' then
      if state.active then notify('Cancel or finish the current turn first', true); return end
      bridge.request('system', {}, function(result, err) if not err then state.system = nil end; response(result, err) end)
    else notify('Use system modify or system default', true) end
  elseif name == 'login' then
    bridge.request('initialize', {}, function(result, err)
      if err then notify(err, true); return end
      vim.cmd('botright new')
      vim.fn.jobstart({ result.cli, 'auth', 'login' }, { term = true })
      vim.cmd.startinsert()
    end)
  elseif name == 'setup' or name == 'update' then
    if bridge.job then notify('Restart Neovim before updating a running SDK environment', true); return end
    bridge.provision(name == 'update', function(_, err) if err then notify(err, true) end end)
  elseif name == 'result' then if state.result then state.result.focus() end
  else notify('Unknown command: ' .. name, true) end
end

function M.setup(opts)
  opts = opts or {}
  if vim.fn.has('nvim-0.11') == 0 then error('nvim-claude requires Neovim 0.11+') end
  bridge.setup(opts, function(method, params)
    local active = state.active
    if not active or active.cancelled or params.request ~= active.id or params.epoch ~= active.epoch or state.epoch ~= active.epoch then return end
    if method == 'partial' then active.partial = params.text; active.view.update(params.text)
    elseif method == 'status' then active.view.title('Claude · ' .. params.text) end
  end)
  api.nvim_create_user_command('NvClaude', function(command) M.command(command.args) end, {
    nargs = '*', force = true, complete = function(lead, command)
      local options = commands
      if command:match('NvClaude%s+system%s+') then options = { 'modify', 'default' }
      elseif command:match('NvClaude%s+watermarks%s+') then options = { 'allow', 'remove', 'replace' }
      elseif command:match('NvClaude%s+sticky%s+') then options = { 'on', 'off' }
      elseif command:match('NvClaude%s+ask%s+') then options = { 'previous' }
      elseif command:match('NvClaude%s+model%s+') then options = { 'manual' } end
      return vim.tbl_filter(function(value) return value:sub(1, #lead) == lead end, options)
    end,
  })
  for _, map in ipairs(state.mappings) do
    local current = vim.fn.maparg(map.lhs, map.mode, false, true)
    if current.callback == map.callback then pcall(vim.keymap.del, map.mode, map.lhs) end
  end
  state.mappings = {}
  if opts.keys ~= false then
    for action, definition in pairs(defaults) do
      local explicit = opts.keys and opts.keys[action] ~= nil
      local lhs = explicit and opts.keys[action] or definition[1]
      if explicit and opts.keys[action] == false then lhs = false end
      if lhs then
        for _, mode in ipairs(definition[2]) do
          if explicit or vim.fn.maparg(lhs, mode) == '' then
            local callback = function()
              if action == 'replace' or action == 'replace_short' then M.invoke('replace', mode == 'x')
              elseif action == 'generate' or action == 'generate_insert' then M.invoke('generate', false)
              elseif action == 'ask' then
                local last = state.last_action
                local previous = mode == 'n' and last and last.action == 'selected-ask' and last.buf == api.nvim_get_current_buf() and targets.valid(last.target)
                M.invoke('ask', mode == 'x', previous)
              elseif action == 'model_manual' then M.model(true)
              else M.command(action) end
            end
            vim.keymap.set(mode, lhs, callback, { silent = true, desc = 'NvClaude ' .. action })
            state.mappings[#state.mappings + 1] = { mode = mode, lhs = lhs, callback = callback }
          end
        end
      end
    end
  end
  local group = api.nvim_create_augroup('NvClaude', { clear = true })
  api.nvim_create_autocmd('VimLeavePre', { group = group, callback = bridge.stop })
end

return M
