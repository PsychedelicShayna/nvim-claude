local M = {}
local a = vim.api
local rpc, targets, ui = require('nvim-claude.rpc'), require('nvim-claude.targets'), require('nvim-claude.ui')
local S = { epoch = 0, remembered = {}, policy = 'allow', mappings = {} }
local punctuation = { ['—'] = '-', ['–'] = '-', ['‘'] = "'", ['’'] = "'", ['“'] = '"', ['”'] = '"', ['…'] = '...', [' '] = ' ' }
local presets = { 'model default', '50k','90k','100k','124k','150k','164k','200k','224k','256k','258k','274k','278k','300k','374k','378k','384k','412k','456k','500k','512k','600k','650k','700k','750k','800k','850k','900k','950k','980k' }
local function notify(text) vim.notify('NvClaude: ' .. text, vim.log.levels.INFO) end
local function normalize(text)
  if S.policy == 'allow' then return text end
  for from, to in pairs(S.opts.punctuation or punctuation) do text = text:gsub(from, S.policy == 'remove' and '' or to) end
  return text
end
local function event(method, p)
  if not S.active or p.epoch ~= S.epoch or p.request_id ~= S.active.id then return end
  if method == 'partial' then
    S.active.raw = S.active.raw .. p.text
    if S.active.operation == 'ask' then S.active.output.set(normalize(S.active.raw)) end
  elseif method == 'status' then
    notify(S.active.operation .. ': ' .. p.state)
  end
end
local function request(method, params, cb)
  rpc.start(S.opts, event)
  return rpc.request(method, params, cb or function(err, result)
    if err then notify(err) elseif result then ui.float(method, type(result) == 'string' and result or vim.inspect(result), a.nvim_get_current_win()) end
  end)
end
local function configure(value)
  request('configure', value, function(err, result)
    if err then notify(err); return end
    S.model = result.model
    local budget = type(result.context_limit_tokens) == 'number' and tostring(result.context_limit_tokens)
      or 'model default (no local ceiling)'
    notify('Model: ' .. result.model .. ', effort: ' .. tostring(result.effort) .. ', budget: ' .. budget)
  end)
end
function M.invoke(operation, visual, previous)
  local b, origin = a.nvim_get_current_buf(), a.nvim_get_current_win()
  local target
  if visual or operation == 'generate' then
    local ok, value = pcall(targets.capture, operation, visual)
    if not ok then notify(value); return end
    target = value
    if S.remembered[b] then targets.release(S.remembered[b]) end
    S.remembered[b] = target
  elseif operation == 'replace' or previous then
    target = S.remembered[b]
    if not targets.valid(target) or (previous and S.last ~= 'ask:' .. b) then notify('Select text first; no valid previous target'); return end
  end
  S.last = operation == 'ask' and target and 'ask:' .. b or operation
  ui.prompt(operation .. ' · ' .. S.model, origin, function(instruction)
    if S.active then notify('Conversation is busy; draft retained. Use :NvClaude cancel.'); return false end
    if target and not targets.valid(target) then notify('Target changed; select it again'); return false end
    local p = { operation = operation, instruction = instruction, epoch = S.epoch }
    if target then
      p.targets = targets.encode(target)
      p.document = { id = 'buffer-' .. b, filetype = vim.bo[b].filetype }
      p.snapshot = table.concat(a.nvim_buf_get_lines(b, 0, -1, false), '\n') .. (vim.bo[b].endofline and '\n' or '')
      p.revision = tostring(a.nvim_buf_get_changedtick(b))
    end
    local out = ui.float(operation .. ' · waiting', '', origin)
    if a.nvim_win_is_valid(origin) then a.nvim_set_current_win(origin) end
    local active = { operation = operation, raw = '', output = out, epoch = S.epoch }
    S.active = active
    active.id = request('turn', p, function(err, result)
      if S.active ~= active or active.epoch ~= S.epoch then return end
      S.active = nil
      if err then out.set(active.raw .. '\n\n' .. err); notify(err); return end
      if operation == 'ask' then out.set(normalize(result.raw)); return end
      if result.validation_error then out.set(result.validation_error .. '\n\n' .. result.raw); return end
      out.set(result.raw)
      local ok, decoded = pcall(vim.json.decode, result.raw)
      if not ok or type(decoded) ~= 'table' then out.set('Invalid edit JSON; buffer unchanged.\n\n' .. result.raw); return end
      if decoded.status == 'needs_input' and type(decoded.message) == 'string' and decoded.replacements == nil then out.set(normalize(decoded.message)); return end
      if decoded.status ~= 'ok' or type(decoded.replacements) ~= 'table' then out.set('Invalid edit envelope; buffer unchanged.\n\n' .. result.raw); return end
      for _, replacement in ipairs(decoded.replacements) do
        if type(replacement.text) == 'string' then replacement.text = normalize(replacement.text) end
      end
      local applied, changed = pcall(targets.apply, target, decoded.replacements)
      if not applied then out.set(tostring(changed) .. '\n\n' .. result.raw)
      else out.set(changed and 'Edit applied. One undo reverses it.' or 'Completed without a text change.'); notify(changed and 'Edit applied' or 'Completed: no change') end
    end)
    return true
  end)
end
local function picker()
  request('models', {}, function(err, models)
    if err then notify(err); return end
    if #models == 0 then notify('Runtime did not announce models; use :NvClaude model manual'); return end
    vim.ui.select(models, { prompt = 'Model', format_item = function(m) return m.displayName .. ' · ' .. m.value end }, function(model)
      if not model then return end
      local function budget(effort)
        vim.ui.select(presets, { prompt = 'Local prompt budget' }, function(limit)
          if limit then configure({ model = model.value, effort = effort or vim.NIL, context_limit_tokens = limit == 'model default' and vim.NIL or tonumber(limit:sub(1,-2)) * 1000 }) end
        end)
      end
      if model.supportsEffort and model.supportedEffortLevels then
        vim.ui.select(model.supportedEffortLevels, { prompt = 'Effort' }, function(effort) if effort then budget(effort) end end)
      else budget(nil) end
    end)
  end)
end
function M.command(args)
  local cmd, arg = args[1] or 'ask', args[2]
  if cmd == 'ask' then M.invoke('ask', false, arg == 'previous')
  elseif cmd == 'replace' or cmd == 'generate' then M.invoke(cmd, false)
  elseif cmd == 'cancel' then
    S.epoch = S.epoch + 1
    if S.active then S.active.output.set(S.active.raw .. '\n\nCanceled; buffer unchanged.'); S.active = nil end
    if rpc.job then request('cancel', {}) end
  elseif cmd == 'new' or cmd == 'clear' or cmd == 'resume' then
    M.command({'cancel'}); S.last = nil
    request(cmd, { id = arg })
  elseif cmd == 'model' then
    if arg == 'manual' then vim.ui.input({ prompt = 'Model expression: ', default = S.model }, function(value) if value then configure({ expression = value }) end end)
    elseif arg then configure({ expression = table.concat(args, ' ', 2) }) else picker() end
  elseif cmd == 'list' then
    request('list', {}, function(err, items)
      if err then notify(err); return end
      vim.ui.select(items, { prompt = 'Saved conversations', format_item = function(item) return item.title .. ' [' .. item.id:sub(1,8) .. ']' end }, function(item) if item then M.command({'resume', item.id}) end end)
    end)
  elseif cmd == 'watermarks' then
    if not vim.tbl_contains({'allow','remove','replace'}, arg) then notify('Use watermarks allow|remove|replace'); return end
    S.policy = arg; notify('Punctuation policy: ' .. arg)
  elseif cmd == 'system' then
    if arg == 'default' then request('system', { reset = true })
    elseif arg == 'modify' then
      request('system', {}, function(err, text)
        if err then notify(err); return end
        local f = ui.float('System prompt · :write to apply', text, a.nvim_get_current_win(), true)
        vim.bo[f.buf].buftype = 'acwrite'; vim.bo[f.buf].bufhidden = 'wipe'
        a.nvim_buf_set_name(f.buf, 'nvclaude-system-' .. f.buf)
        a.nvim_create_autocmd('BufWriteCmd', { buffer = f.buf, callback = function()
          request('system', { text = table.concat(a.nvim_buf_get_lines(f.buf, 0, -1, false), '\n') }, function(e)
            if e then notify(e) else vim.bo[f.buf].modified = false; notify('System prompt changed for next turn') end
          end)
        end })
      end)
    else notify('Use system modify|default') end
  elseif cmd == 'login' or cmd == 'update' then
    if S.active or rpc.job then notify('Restart Neovim before login/update so no runtime is using the environment'); return end
    rpc.login(S.opts, cmd == 'update')
  elseif vim.tbl_contains({'save','sticky','compact','info'}, cmd) then request(cmd, { value = arg })
  else notify('Unknown command: ' .. cmd) end
end
function M.setup(opts)
  opts = opts or {}
  S.opts = vim.tbl_deep_extend('force', { data_dir = vim.fn.stdpath('data') .. '/nvim-claude', state_dir = vim.fn.stdpath('state') .. '/nvim-claude' }, opts)
  S.model = opts.model or S.model or 'claude-haiku-5-5'
  if vim.fn.has('nvim-0.11') == 0 then error('nvim-claude requires Neovim 0.11+') end
  for _, mapping in ipairs(S.mappings) do
    local current = vim.fn.maparg(mapping.key, mapping.mode, false, true)
    if current.desc == mapping.desc then pcall(vim.keymap.del, mapping.mode, mapping.key) end
  end
  S.mappings = {}
  a.nvim_create_user_command('NvClaude', function(info) M.command(info.fargs) end, { nargs = '*', force = true,
    complete = function(lead) return vim.tbl_filter(function(s) return s:sub(1,#lead) == lead end,
      {'ask','replace','generate','cancel','model','clear','new','sticky','save','compact','info','list','resume','watermarks','system','login','update'}) end })
  local actions = {
    replace = {'<leader>cc', {'n','x'}, 'replace'}, replace_short = {'<leader>c', {'n','x'}, 'replace'},
    ask = {'<leader>ca', {'n','x'}, 'ask'}, generate = {'<leader>ci', {'n'}, 'generate'},
    generate_insert = {false, {'i'}, 'generate'}, model = {'<leader>cm', {'n'}, 'model'}, model_manual = {'<leader>cM', {'n'}, 'model manual'},
    clear = {'<leader>cC', {'n'}, 'clear'}, new = {'<leader>cn', {'n'}, 'new'}, sticky = {'<leader>cS', {'n'}, 'sticky'},
    save = {'<leader>cs', {'n'}, 'save'}, info = {'<leader>cx', {'n'}, 'info'}, list = {'<leader>cl', {'n'}, 'list'},
  }
  if opts.keys ~= false then
    for name, action in pairs(actions) do
      local explicit = opts.keys and opts.keys[name] ~= nil
      local key = explicit and opts.keys[name] or action[1]
      if explicit and opts.keys[name] == false then key = false end
      if key then
        for _, mode in ipairs(action[2]) do
          if explicit or vim.fn.maparg(key, mode) == '' then
            local desc = 'NvClaude ' .. name
            vim.keymap.set(mode, key, function()
              if action[3] == 'ask' then M.invoke('ask', mode == 'x', mode == 'n' and S.last == 'ask:' .. a.nvim_get_current_buf() and targets.valid(S.remembered[a.nvim_get_current_buf()]))
              elseif action[3] == 'replace' or action[3] == 'generate' then M.invoke(action[3], mode == 'x')
              else M.command(vim.split(action[3], ' ')) end
            end, { desc = desc })
            table.insert(S.mappings, {key=key,mode=mode,desc=desc})
          end
        end
      end
    end
  end
  local group = a.nvim_create_augroup('NvClaude', { clear = true })
  a.nvim_create_autocmd('VimLeavePre', { group = group, callback = rpc.stop })
end
return M
