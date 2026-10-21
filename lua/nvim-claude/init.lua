local backend = require('nvim-claude.backend')
local targets = require('nvim-claude.targets')
local M = {}
local defaults = { replace = '<leader>cc', replace_short = '<leader>c', ask = '<leader>ca',
  generate = '<leader>ci', generate_insert = false, model = '<leader>cm',
  model_manual = '<leader>cM', clear = '<leader>cC', new = '<leader>cn',
  sticky = '<leader>cS', save = '<leader>cs', info = '<leader>cx', list = '<leader>cl' }
local actions = { 'ask', 'replace', 'generate', 'model', 'model_manual', 'clear', 'new',
  'sticky', 'save', 'info', 'list', 'compact', 'cancel', 'system', 'watermarks', 'login', 'update' }
local config = { model = 'claude-haiku-5-5', effort = 'low', limit = 100000 }
local opts, keymaps, baseline, active = {}, {}, {}, nil
local result_win, result_buf, result_origin
local watermarks = 'allow'
local punctuation = { ['—'] = '-', ['–'] = '-', ['‘'] = "'", ['’'] = "'",
  ['“'] = '"', ['”'] = '"', ['…'] = '...', ['\194\160'] = ' ' }
local catalogue, state = {}, {}
local system_override
local presets = { 'model default', '50k', '90k', '100k', '124k', '150k', '164k', '200k',
  '224k', '256k', '258k', '274k', '278k', '300k', '374k', '378k', '384k',
  '412k', '456k', '500k', '512k', '600k', '650k', '700k', '750k', '800k',
  '850k', '900k', '950k', '980k' }

local function notify(text, severity)
  vim.notify('nvim-claude: ' .. text, severity or vim.log.levels.INFO)
end
local function normalize(text)
  if watermarks == 'allow' then return text end
  for char, replacement in pairs(punctuation) do
    text = text:gsub(char, watermarks == 'remove' and '' or replacement)
  end
  return text
end
local function sized(text)
  local lines = vim.split(text, '\n', { plain = true })
  local width = math.min(math.max(32, math.floor(vim.o.columns * 0.65)), vim.o.columns - 4)
  local height = math.min(math.max(2, #lines), math.max(2, vim.o.lines - 6))
  return lines, width, height
end
local function float(text, title, origin, existing)
  local lines, width, height = sized(text)
  local buf = existing and result_buf or vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'; vim.bo[buf].bufhidden = 'wipe'; vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = not existing
  local source = origin and vim.api.nvim_win_is_valid(origin) and origin or vim.api.nvim_get_current_win()
  local row, col = 2, 2
  if vim.api.nvim_win_is_valid(source) then
    local pos = vim.api.nvim_win_get_position(source)
    local cursor = vim.api.nvim_win_get_cursor(source)
    row = math.min(math.max(1, pos[1] + cursor[1]), math.max(1, vim.o.lines - height - 3))
    col = math.min(math.max(1, pos[2] + cursor[2]), math.max(1, vim.o.columns - width - 2))
  end
  local win = vim.api.nvim_open_win(buf, true, { relative = 'editor', row = row, col = col,
    width = width, height = height, style = 'minimal', border = 'rounded', title = title })
  return buf, win
end
local function close_result()
  if result_win and vim.api.nvim_win_is_valid(result_win) then vim.api.nvim_win_close(result_win, true) end
  result_win = nil
  if result_origin and vim.api.nvim_win_is_valid(result_origin) then vim.api.nvim_set_current_win(result_origin) end
end
local function show(text, title, origin, append)
  local display = normalize(text)
  if append and result_win and vim.api.nvim_win_is_valid(result_win) then
    local lines = vim.split(display, '\n', { plain = true })
    vim.bo[result_buf].modifiable = true
    vim.api.nvim_buf_set_lines(result_buf, 0, -1, false, lines)
    vim.bo[result_buf].modifiable = false
    return
  end
  if result_win and vim.api.nvim_win_is_valid(result_win) then vim.api.nvim_win_close(result_win, true) end
  result_origin = origin
  result_buf, result_win = float(display, title, origin, false)
  vim.bo[result_buf].modifiable = false
  vim.keymap.set('n', 'q', close_result, { buffer = result_buf, nowait = true })
  vim.keymap.set('n', '<Esc>', close_result, { buffer = result_buf, nowait = true })
end
local function budget(input)
  local amount, unit = input:match('^(%d+)([km]?)$')
  if not amount then return nil end
  return tonumber(amount) * ({ k = 1000, m = 1000000, [''] = 1 })[unit]
end
local function parse(expression)
  local model = vim.trim(expression)
  local effort = model:match(':([%a]+)$')
  local explicit_effort = effort and vim.tbl_contains({ 'low', 'medium', 'high', 'xhigh', 'max' }, effort)
  if explicit_effort then
    model = model:sub(1, -#effort - 2)
  else effort = config.effort end
  local limit = config.limit
  local explicit = model:match('%[limit=(%d+[km]?)%]$')
  if explicit then limit = budget(explicit); model = model:sub(1, #model - #explicit - 8)
  else
    local number = model:match('%[(%d+[km]?)%]$')
    if number then
      local prefix = model:sub(1, #model - #number - 2)
      local native = number == '1m' and prefix:match('^claude%-.+%-%d+%-%d+$') and not prefix:find('%[')
      if not native then limit = budget(number); model = prefix end
    end
  end
  if model == '' then return nil, 'Model ID cannot be empty' end
  return { model = model, effort = effort, limit = limit }, nil, explicit_effort
end
local function context(buf, target)
  local name = 'buffer-' .. buf
  local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n') .. '\n'
  local rev = vim.api.nvim_buf_get_changedtick(buf)
  local old = baseline[buf]
  local kind, content
  if old and old.rev == rev and old.text == text then kind = 'unchanged'
  elseif old and #old.text < 100000 and #text < 100000 then
    local diff = vim.diff(old.text, text, { result_type = 'unified', ctxlen = 3 })
    if #diff < #text then kind = 'diff'; content = diff end
  end
  local fallback = { kind = 'snapshot', revision = 'r' .. rev, text = text }
  if #text > 120000 and target then
    local row = targets.envelope(target)[1].start[1]
    local first = math.max(0, row - 60)
    local last = math.min(vim.api.nvim_buf_line_count(buf), row + 61)
    fallback = { kind = 'excerpt', revision = 'r' .. rev, start_row = first,
      end_row = last, total_rows = vim.api.nvim_buf_line_count(buf),
      text = table.concat(vim.api.nvim_buf_get_lines(buf, first, last, false), '\n') }
  end
  if not kind then kind, content = fallback.kind, fallback.text end
  local envelope = { kind = kind, revision = 'r' .. rev }
  if kind == 'diff' then envelope.base_revision = 'r' .. old.rev; envelope.text = content
  elseif kind == 'excerpt' then envelope = fallback
  elseif content then envelope.text = content end
  return { id = name, filetype = vim.bo[buf].filetype }, envelope,
    { rev = rev, text = text, complete = kind ~= 'excerpt' }, fallback
end
local function validate(text, target)
  local ok, envelope = pcall(vim.json.decode, text)
  if not ok or type(envelope) ~= 'table' then return nil, 'Edit result is not a JSON object' end
  if envelope.status == 'needs_input' and type(envelope.message) == 'string' and envelope.replacements == nil then
    return nil, envelope.message
  end
  if envelope.status ~= 'ok' or type(envelope.replacements) ~= 'table' or #envelope.replacements ~= #target.segments then
    return nil, 'Edit result has an invalid status or replacement count'
  end
  local seen = {}
  for _, item in ipairs(envelope.replacements) do
    if type(item) ~= 'table' or type(item.text) ~= 'string' or type(item.id) ~= 'string' or seen[item.id] then
      return nil, 'Invalid or duplicate target in edit result'
    end
    seen[item.id] = true
    if target.block and item.text:find('\n', 1, true) then return nil, 'Block replacement contains newline' end
  end
  for _, segment in ipairs(target.segments) do if not seen[segment.id] then return nil, 'Missing target in edit result' end end
  return envelope.replacements
end
local function event(method, params)
  if method == 'catalogue' then catalogue = params.server or {}; state.runtime = params.runtime; return end
  if method == 'state' then state = params; baseline = {}; return end
  local pending = active
  if not pending or not pending.id or pending.id ~= params.id or pending.epoch ~= params.epoch then return end
  if method == 'status' then notify(pending.operation .. ' (' .. params.status .. ')')
  elseif method == 'partial' then
    pending.raw = pending.raw .. params.text
    if pending.operation == 'ask' then show(pending.raw, 'Claude · ask (streaming)', pending.origin, true) end
  elseif method == 'result' then
    active = nil
    if pending.document and pending.snapshot and pending.snapshot.complete then
      baseline[pending.target.buf] = pending.snapshot
    end
    if pending.operation == 'ask' then show(params.text, 'Claude · answer', pending.origin, true); return end
    local replacements, err = validate(params.text, pending.target)
    if not replacements then show(params.text .. '\n\n' .. err, 'Claude · not applied', pending.origin); return end
    for _, item in ipairs(replacements) do item.text = normalize(item.text) end
    local applied, why = targets.apply(pending.target, replacements)
    if not applied then show(params.text .. '\n\n' .. why, 'Claude · not applied', pending.origin)
    else notify('Edit applied') end
  elseif method == 'error' then active = nil; baseline = {}; notify(params.message, vim.log.levels.ERROR)
  elseif method == 'cancelled' then active = nil; baseline = {}; notify('Request canceled') end
end

local function prompt(operation, target)
  if active then notify('Conversation busy; current draft is unchanged', vim.log.levels.WARN); return end
  local origin = vim.api.nvim_get_current_win()
  local buf, win = float('', 'Claude · ' .. operation .. ' · ' .. config.model, origin)
  local function dismiss()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    if vim.api.nvim_win_is_valid(origin) then vim.api.nvim_set_current_win(origin) end
  end
  local function submit()
    local instruction = vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n'))
    if instruction == '' then return end
    if active then notify('Conversation busy; draft retained', vim.log.levels.WARN); return end
    local envelope = { operation = operation, instruction = instruction }
    local snapshot, fallback
    if target then
      envelope.document, envelope.context, snapshot, fallback = context(target.buf, target)
      envelope.targets = targets.envelope(target)
    end
    local pending = { operation = operation, target = target, snapshot = snapshot, document = target ~= nil,
      origin = origin, raw = '' }
    active = pending
    backend.call('request', { envelope = envelope, fallback_context = fallback }, function(response, err, id)
      if active ~= pending then return end
      if err then active = nil; notify(err, vim.log.levels.ERROR)
      else pending.id = id; pending.epoch = response.epoch end
    end)
    dismiss()
  end
  vim.keymap.set({ 'i', 'n' }, '<C-s>', submit, { buffer = buf })
  vim.keymap.set('n', '<CR>', submit, { buffer = buf })
  vim.keymap.set('n', '<Esc>', dismiss, { buffer = buf })
  vim.cmd('startinsert')
end

local function ask(previous, visual)
  local target
  if visual then target = targets.capture('ask', true)
  elseif previous then
    target = targets.previous(vim.api.nvim_get_current_buf(), true)
    if not target then notify('No valid selected-ask target in this buffer', vim.log.levels.WARN); return end
  else targets.general_ask() end
  prompt('ask', target)
end
local function replace(visual)
  local target = visual and targets.capture('replace', true) or targets.previous(vim.api.nvim_get_current_buf(), false)
  if not target then notify('Select text before replacing it', vim.log.levels.WARN); return end
  prompt('replace', target)
end
local function generate() prompt('generate', targets.capture('generate', false)) end
local function action(method, params, after)
  backend.call(method, params, function(result, err)
    if err then notify(err, vim.log.levels.ERROR)
    elseif after then after(result) else notify(method .. ' completed') end
  end)
end
local function model_menu()
  action('catalogue', {}, function(info)
    catalogue = info or {}
    local models = catalogue.models or {}
    if #models == 0 then notify('Runtime did not announce models; use model manual', vim.log.levels.WARN); return end
    vim.ui.select(models, { prompt = 'Claude model', format_item = function(item)
      return type(item) == 'table' and (item.displayName or item.value or item.id) or item
    end }, function(item)
      if not item then return end
      local slug = type(item) == 'table' and (item.value or item.id) or item
      local efforts = type(item) == 'table' and item.supportedEffortLevels or nil
      local function limit_picker(effort)
        vim.ui.select(presets, { prompt = 'Local context budget' }, function(choice)
          if not choice then return end
          local selected = { model = slug, effort = effort,
            limit = choice == 'model default' and vim.NIL or budget(choice) }
          if selected.limit == vim.NIL then selected.limit = nil end
          action('model', { config = selected, explicit_effort = effort ~= nil }, function(result)
            config = result.config; notify('Model: ' .. config.model)
          end)
        end)
      end
      if efforts and #efforts > 0 then vim.ui.select(efforts, { prompt = 'Effort' }, function(level)
        if level then limit_picker(level) end
      end) else limit_picker(nil) end
    end)
  end)
end
local function manual()
  vim.ui.input({ prompt = 'Model [budget]:effort', default = config.model }, function(text)
    if not text then return end
    local parsed, err, explicit_effort = parse(text)
    if not parsed then notify(err, vim.log.levels.ERROR); return end
    action('model', { config = parsed, explicit_effort = explicit_effort }, function(result)
      config = result.config; notify('Model: ' .. config.model)
    end)
  end)
end
local function info()
  action('info', {}, function(result)
    show(vim.inspect(result), 'Claude · info', vim.api.nvim_get_current_win())
  end)
end
local function list()
  action('list', {}, function(entries)
    if #entries == 0 then notify('No saved conversations'); return end
    vim.ui.select(entries, { prompt = 'Saved conversations', format_item = function(entry)
      return os.date('%y:%m:%d:%H:%M:%S', entry.created) .. ' - ' .. entry.title .. ' [' .. entry.id:sub(1, 8) .. ']'
    end }, function(entry) if entry then action('resume', { id = entry.id }) end end)
  end)
end
local function system(command)
  if command == 'default' then system_override = nil; action('system', { text = vim.NIL }); return end
  if command ~= 'modify' then notify('Use :NvClaude system modify|default', vim.log.levels.WARN); return end
  local path = vim.fs.joinpath(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)))), 'resources/system.txt')
  local original = system_override or vim.fn.readfile(path)
  vim.cmd('new')
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype = 'acwrite'; vim.bo[buf].filetype = 'text'
  vim.api.nvim_buf_set_name(buf, 'nvim-claude-system-' .. buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, type(original) == 'table' and original or vim.split(original, '\n'))
  vim.api.nvim_create_autocmd('BufWriteCmd', { buffer = buf, callback = function()
    system_override = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
    action('system', { text = system_override }, function() vim.bo[buf].modified = false; notify('System prompt updated for subsequent turns') end)
  end })
end
function M.command(args)
  local parts = vim.split(vim.trim(args or ''), '%s+')
  local name = parts[1]
  if name == 'ask' then ask(parts[2] == 'previous', false)
  elseif name == 'replace' then replace(false)
  elseif name == 'generate' then generate()
  elseif name == 'model' then model_menu()
  elseif name == 'model_manual' then manual()
  elseif name == 'list' then list()
  elseif name == 'info' then info()
  elseif name == 'system' then system(parts[2])
  elseif name == 'watermarks' then
    if not vim.tbl_contains({ 'allow', 'remove', 'replace' }, parts[2]) then notify('Use allow, remove, or replace', vim.log.levels.WARN)
    else watermarks = parts[2]; notify('Punctuation: ' .. watermarks) end
  elseif name == 'sticky' then action('sticky', { enabled = parts[2] == 'on' and true or parts[2] == 'off' and false or not state.sticky })
  elseif name == 'login' then
    action('initialize', {}, function(result)
      vim.cmd('botright new')
      vim.fn.termopen({ result.runtime.cli_path, 'login' })
      vim.cmd('startinsert')
    end)
  elseif name == 'update' then
    notify('After closing Neovim, run ' .. vim.fn.stdpath('data') ..
      '/nvim-claude/venv/bin/python -m pip install --upgrade claude-agent-sdk; restart Neovim')
  elseif vim.tbl_contains({ 'clear', 'new', 'save', 'compact', 'cancel' }, name) then
    if name == 'cancel' then
      active = nil
      backend.discard_pending_request()
    end
    action(name, {})
  else notify('Use :NvClaude ' .. table.concat(actions, '|'), vim.log.levels.WARN) end
end
function M.setup(options)
  opts = options or {}
  backend.configure(opts, event)
  local group = vim.api.nvim_create_augroup('NvClaudeLifecycle', { clear = true })
  vim.api.nvim_create_autocmd('VimLeavePre', { group = group, callback = backend.stop })
  vim.api.nvim_create_user_command('NvClaude', function(cmd) M.command(cmd.args) end, {
    nargs = '*', force = true, complete = function(arglead, line)
      if not line:find(' ', 1, true) then return actions end
      local words = vim.split(line, '%s+')
      if #words < 3 then return vim.tbl_filter(function(word) return vim.startswith(word, arglead) end, actions) end
      local variants = { ask = { 'previous' }, sticky = { 'on', 'off' },
        watermarks = { 'allow', 'remove', 'replace' }, system = { 'modify', 'default' } }
      return variants[words[2]] or {}
    end })
  for _, map in ipairs(keymaps) do
    local current = vim.fn.maparg(map.lhs, map.mode, false, true)
    if type(current) == 'table' and current.desc == 'nvim-claude ' .. map.name then
      pcall(vim.keymap.del, map.mode, map.lhs)
    end
  end
  keymaps = {}
  if opts.keys == false then return end
  local keys = vim.tbl_extend('force', defaults, opts.keys or {})
  local bindings = {
    replace = { { 'n', function() replace(false) end }, { 'x', function() replace(true) end } },
    replace_short = { { 'n', function() replace(false) end }, { 'x', function() replace(true) end } },
    ask = { { 'n', function() ask(targets.previous(vim.api.nvim_get_current_buf(), true) ~= nil, false) end },
      { 'x', function() ask(false, true) end } },
    generate = { { 'n', generate } }, generate_insert = { { 'i', generate } },
    model = { { 'n', model_menu } }, model_manual = { { 'n', manual } },
    clear = { { 'n', function() M.command('clear') end } }, new = { { 'n', function() M.command('new') end } },
    sticky = { { 'n', function() M.command('sticky') end } }, save = { { 'n', function() M.command('save') end } },
    info = { { 'n', info } }, list = { { 'n', list } },
  }
  for name, binding in pairs(bindings) do
    local lhs = keys[name]
    if type(lhs) == 'string' then
      for _, pair in ipairs(binding) do
        local occupied = vim.fn.maparg(lhs, pair[1], false, true)
        if (opts.keys and opts.keys[name] ~= nil) or not occupied or vim.tbl_isempty(occupied) then
          vim.keymap.set(pair[1], lhs, pair[2], { desc = 'nvim-claude ' .. name, silent = true })
          keymaps[#keymaps + 1] = { mode = pair[1], lhs = lhs, name = name }
        end
      end
    end
  end
end
return M
