local M = {}
local transport = require('nvim-claude.transport')
local target = require('nvim-claude.target')
local ui = require('nvim-claude.ui')
local ns = vim.api.nvim_create_namespace('nvim-claude-status')
local defaults = {
  replace = '<leader>cc', replace_short = '<leader>c', ask = '<leader>ca', generate = '<leader>ci',
  generate_insert = false, model = '<leader>cm', model_manual = '<leader>cM', clear = '<leader>cC',
  new = '<leader>cn', sticky = '<leader>cS', save = '<leader>cs', info = '<leader>cx', list = '<leader>cl',
}
local configured, owned = {}, {}
local model = { model = 'claude-haiku-5-5', effort = 'low', limit = 100000 }
local state = { sticky = false, last_action = nil, selected_ask = nil, watermarks = 'allow',
  epoch = 0, busy = false, baselines = {}, capabilities = {}, system = nil }
local punctuation = { ['—'] = '-', ['–'] = '-', ['‘'] = "'", ['’'] = "'", ['“'] = '"', ['”'] = '"', ['…'] = '...', ['\194\160'] = ' ' }
local presets = { 50000,90000,100000,124000,150000,164000,200000,224000,256000,258000,274000,278000,300000,374000,378000,384000,412000,456000,500000,512000,600000,650000,700000,750000,800000,850000,900000,950000,980000 }

local function note(text, level) vim.notify('nvim-claude: ' .. text, level or vim.log.levels.INFO) end
local function rpc(method, params, callback)
  transport.request(method, params or {}, function(err, value)
    if err then note(err, vim.log.levels.ERROR) end
    if callback then callback(err, value) end
  end)
end
local function present(text)
  if state.watermarks == 'allow' then return text end
  return (text:gsub('[\194-\244][\128-\191]*', function(char)
    if punctuation[char] then return state.watermarks == 'remove' and '' or punctuation[char] end
    return char
  end))
end
local function model_expr(expr)
  local slug, effort = expr:match('^(.-):([%a]+)$')
  if slug and ({low=true,medium=true,high=true,xhigh=true,max=true})[effort] then
    expr = slug
  else effort = model.effort end
  local limit = model.limit
  local base, explicit = expr:match('^(.-)%[limit=(%d+[kKmM]?)%]$')
  if not base then
    local candidate, suffix = expr:match('^(.-)%[(%d+[kKmM]?)%]$')
    if candidate and not (suffix:lower() == '1m' and candidate:match('^claude%-opus%-')) then
      base, explicit = candidate, suffix
    end
  end
  if base then
    expr = base
    local count, unit = explicit:lower():match('^(%d+)([km]?)$')
    limit = tonumber(count) * ({ k = 1000, m = 1000000, [''] = 1 })[unit]
  end
  if expr == '' then return nil, 'Enter a model slug' end
  return { model = expr, effort = effort, limit = limit }
end
local function configure(next_model)
  rpc('configure', { config = next_model }, function(err)
    if not err then model = next_model; state.baselines = {}; note('Model: ' .. model.model) end
  end)
end
local function context(buf)
  local all = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
  local rev = tostring(vim.api.nvim_buf_get_changedtick(buf)) .. ':' .. tostring(#all)
  local old = state.baselines[buf]
  if old and old.revision == rev and old.text == all then return { kind = 'unchanged', revision = rev }, all end
  if old and old.text then
    local diff = vim.diff(old.text, all, { result_type = 'unified' })
    if #diff < #all then return { kind = 'diff', base_revision = old.revision, revision = rev, text = diff }, all end
  end
  return { kind = 'snapshot', revision = rev, text = all }, all
end
local function do_request(op, visual, previous, insert)
  if state.busy then return note('Conversation busy; current draft has not been submitted', vim.log.levels.WARN) end
  local capture, err
  if previous and op == 'ask' then
    capture = state.selected_ask
    if not capture or capture.buf ~= vim.api.nvim_get_current_buf() or not target.valid(capture) then
      return note('No valid selected-ask target', vim.log.levels.WARN)
    end
  else
    capture, err = target.capture(previous and 'previous' or op, visual, insert)
  end
  if not capture then return note(err, vim.log.levels.WARN) end
  if op == 'ask' and not visual and not previous then capture.targets = {} end
  if op ~= 'ask' then state.selected_ask = nil end
  ui.prompt(capture, model.model, function(instruction, close_prompt)
    if state.busy then return note('Conversation busy; draft preserved') end
    close_prompt()
    local data = { operation = op, instruction = instruction }
    if #capture.targets > 0 then
      data.document = { id = 'buffer-' .. capture.buf, filetype = vim.bo[capture.buf].filetype }
      data.context, capture.snapshot = context(capture.buf)
      data.targets = target.payload(capture)
    end
    local epoch = state.epoch
    state.busy = true
    local update = ui.answer(op == 'ask' and 'Answer (streaming)' or 'Edit result (streaming)', capture.win)
    state.partial = update
    rpc('turn', { input = data }, function(failure, result)
      state.busy = false
      state.partial = nil
      if epoch ~= state.epoch then return end
      if failure then return update('Request failed: ' .. failure) end
      if not result then return update('Bridge returned no result') end
      if data.document then
        state.baselines[capture.buf] = { revision = data.context.revision, text = capture.snapshot }
      end
      local text = result.text or ''
      if op == 'ask' then
        update(present(text))
        if #capture.targets > 0 then
          state.selected_ask = capture
          state.last_action = 'selected_ask'
        else state.last_action = 'ask'; state.selected_ask = nil end
        return
      end
      local ok, parsed = pcall(vim.json.decode, text)
      if not ok or type(parsed) ~= 'table' then return update('Invalid edit JSON; source unchanged:\n' .. text) end
      if parsed.status == 'needs_input' and type(parsed.message) == 'string' then return update(parsed.message) end
      if parsed.status ~= 'ok' or type(parsed.replacements) ~= 'table' then
        return update('Invalid edit envelope; source unchanged:\n' .. text)
      end
      for _, item in ipairs(parsed.replacements) do
        if type(item) == 'table' and type(item.text) == 'string' then item.text = present(item.text) end
      end
      local applied, reason = target.apply(capture, parsed.replacements)
      if not applied then return update('Result not applied: ' .. reason .. '\n\n' .. text) end
      state.last_action = op
      update('Applied ' .. op .. ' to the captured target.')
    end)
  end)
end

local function menu()
  rpc('info', {}, function(err, info)
    if err then return end
    local models = info.server and info.server.models or state.capabilities.server and state.capabilities.server.models
    if type(models) ~= 'table' or #models == 0 then
      return note('Runtime did not announce a model catalogue; use :NvClaude model manual', vim.log.levels.WARN)
    end
    vim.ui.select(models, { prompt = 'Claude model', format_item = function(item)
      return type(item) == 'table' and (item.displayName or item.value or item.id or vim.inspect(item)) or tostring(item)
    end }, function(selected)
      if not selected then return end
      local slug = type(selected) == 'table' and (selected.value or selected.id) or selected
      local efforts = type(selected) == 'table' and selected.supportedEffortLevels or nil
      local function budget(effort)
        local choices = { 'model default' }
        for _, value in ipairs(presets) do choices[#choices + 1] = tostring(value / 1000) .. 'k' end
        vim.ui.select(choices, { prompt = 'Local context budget' }, function(choice)
          if not choice then return end
          configure({ model = slug, effort = effort, limit = choice == 'model default' and vim.NIL or tonumber(choice:sub(1, -2)) * 1000 })
        end)
      end
      if type(efforts) == 'table' and #efforts > 0 then
        vim.ui.select(efforts, { prompt = 'Effort' }, function(effort) if effort then budget(effort) end end)
      else budget(nil) end
    end)
  end)
end

local function action(name, args)
  args = args or {}
  if name == 'replace' then return do_request('replace', args.visual, false, false) end
  if name == 'generate' then return do_request('generate', false, false, args.insert) end
  if name == 'ask' then
    local previous = args.previous or (not args.command and not args.visual and state.last_action == 'selected_ask'
      and state.selected_ask and state.selected_ask.buf == vim.api.nvim_get_current_buf() and target.valid(state.selected_ask))
    return do_request('ask', args.visual, previous, false)
  end
  if name == 'cancel' then
    state.epoch = state.epoch + 1
    state.busy = false
    state.partial = nil
    return rpc('cancel', {}, function() note('Request canceled') end)
  end
  if name == 'model' then return menu() end
  if name == 'model_manual' then
    return vim.ui.input({ prompt = 'Claude model expression: ', default = model.model }, function(expr)
      if not expr then return end
      local parsed, err = model_expr(expr)
      if not parsed then return note(err, vim.log.levels.ERROR) end
      configure(parsed)
    end)
  end
  if name == 'login' then return transport.login() end
  if name == 'watermarks' then
    if not ({ allow=true, remove=true, replace=true })[args.value] then return note('Use allow, remove or replace', vim.log.levels.ERROR) end
    state.watermarks = args.value
    return note('Punctuation normalization: ' .. args.value)
  end
  if name == 'system' then
    if args.value == 'default' then return rpc('system', {}, function(err) if not err then state.system = nil; note('Default system prompt restored') end end) end
    if args.value ~= 'modify' then return note('Use system modify or system default', vim.log.levels.ERROR) end
    local file = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':h:h:h') .. '/resources/system.txt'
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, 'nvim-claude-system-' .. buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, state.system and vim.split(state.system, '\n') or vim.fn.readfile(file))
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_create_autocmd('BufWriteCmd', { buffer = buf, callback = function()
      local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
      rpc('system', { prompt = text }, function(err)
        if not err then state.system = text; vim.bo[buf].modified = false; note('System prompt updated for next turn') end
      end)
    end })
    return
  end
  if name == 'sticky' then
    local enabled = args.value == 'on' or (args.value ~= 'off' and not state.sticky)
    return rpc('sticky', { enabled = enabled }, function(err) if not err then state.sticky = enabled end end)
  end
  if name == 'info' then
    return rpc('info', {}, function(err, info)
      if not err then ui.message('Claude session info', vim.inspect(info) .. '\nCache lifetime: estimated, not a live cache entry.\nSubscription TTL ~1h; API/credits ~5m.', vim.api.nvim_get_current_win()) end
    end)
  end
  if name == 'list' then
    return rpc('list', {}, function(err, entries)
      if err then return end
      vim.ui.select(entries, { prompt = 'Saved conversations', format_item = function(item)
        return os.date('%y:%m:%d:%H:%M:%S', item.last) .. ' - ' .. (item.title or '') .. ' [' .. item.id:sub(1, 8) .. ']'
      end }, function(item)
        if not item then return end
        rpc('resume', { session = item.id }, function(failure, result)
          if not failure then state.epoch = result.epoch; state.baselines = {}; model = result.model; note('Resumed ' .. item.id) end
        end)
      end)
    end)
  end
  rpc(name, {}, function(err, result)
    if not err and (name == 'new' or name == 'clear') then
      state.epoch = result.epoch
      state.baselines = {}; state.selected_ask = nil; state.last_action = nil
      note('Conversation ' .. name)
    end
  end)
end

function M.setup(opts)
  opts = opts or {}
  transport.interpreter = opts.python
  transport.events(function(method, params)
    if method == 'partial' and state.partial and params.epoch == state.epoch then
      state.partial(present(params.text or ''))
    end
    if method == 'capabilities' then state.capabilities = params end
  end)
  pcall(vim.api.nvim_del_user_command, 'NvClaude')
  local commands = { 'ask','replace','generate','cancel','new','clear','save','sticky','compact','list','info','model','login','watermarks','system' }
  vim.api.nvim_create_user_command('NvClaude', function(spec)
    local parts = vim.split(spec.args, '%s+', { trimempty = true })
    local sub = parts[1] or 'ask'
    if sub == 'model' and parts[2] == 'manual' then sub = 'model_manual' end
    if sub == 'ask' and parts[2] == 'previous' then action('ask', { previous = true, command = true })
    else action(sub, { value = parts[2], command = true }) end
  end, { nargs = '*', complete = function(arg, line)
    local choices = line:match('^%s*NvClaude%s+%S+%s+') and { 'previous','manual','allow','remove','replace','on','off','modify','default' } or commands
    return vim.tbl_filter(function(x) return x:sub(1, #arg) == arg end, choices)
  end })
  for _, map in ipairs(owned) do pcall(vim.keymap.del, map.mode, map.lhs) end
  owned = {}
  local keys = opts.keys == false and {} or vim.tbl_extend('force', defaults, opts.keys or {})
  local modes = { replace={'n','x'}, replace_short={'n','x'}, ask={'n','x'}, generate={'n'},
    generate_insert={'i'}, model={'n'}, model_manual={'n'}, clear={'n'}, new={'n'}, sticky={'n'}, save={'n'}, info={'n'}, list={'n'} }
  for name, lhs in pairs(keys) do
    if type(lhs) == 'string' and modes[name] then
      for _, mode in ipairs(modes[name]) do
        local existing = vim.fn.maparg(lhs, mode)
        local explicit = opts.keys and type(opts.keys) == 'table' and opts.keys[name] ~= nil
        if existing == '' or explicit then
          local command = name == 'replace_short' and 'replace' or name == 'generate_insert' and 'generate' or name
          vim.keymap.set(mode, lhs, function()
            action(command, { visual = mode == 'x', insert = mode == 'i' })
          end, { silent = true, desc = 'nvim-claude ' .. name })
          owned[#owned + 1] = { mode = mode, lhs = lhs }
        end
      end
    end
  end
end

return M
