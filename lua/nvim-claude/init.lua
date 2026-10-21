local M = {}
local api = vim.api
local target = require('nvim-claude.targets')
local rpc = require('nvim-claude.rpc')
local ui = require('nvim-claude.ui')
local state = { epoch = 0, busy = false, remembered = {}, ask = nil, maps = {}, model = 'claude-haiku-5-5' }
local options
local defaults = {
  replace = { '<leader>cc', { 'n', 'x' } }, replace_short = { '<leader>c', { 'n', 'x' } },
  ask = { '<leader>ca', { 'n', 'x' } }, generate = { '<leader>ci', { 'n' } },
  generate_insert = { false, { 'i' } }, model = { '<leader>cm', { 'n' } },
  model_manual = { '<leader>cM', { 'n' } }, clear = { '<leader>cC', { 'n' } },
  new = { '<leader>cn', { 'n' } }, sticky = { '<leader>cS', { 'n' } },
  save = { '<leader>cs', { 'n' } }, info = { '<leader>cx', { 'n' } }, list = { '<leader>cl', { 'n' } },
}
local commands = { 'ask', 'replace', 'generate', 'cancel', 'new', 'clear', 'save', 'sticky', 'compact', 'list', 'info', 'model', 'watermarks', 'system', 'login', 'update', 'result' }
local limits = { 50, 90, 100, 124, 150, 164, 200, 224, 256, 258, 274, 278, 300, 374, 378, 384, 412, 456, 500, 512, 600, 650, 700, 750, 800, 850, 900, 950, 980 }
local function notify(message, error) vim.notify('nvim-claude: ' .. message, error and vim.log.levels.ERROR or vim.log.levels.INFO) end

local function request(method, params, callback)
  rpc.request(method, params or {}, function(result, err)
    if err then notify(err, true) end
    if result and result.config then state.model = result.config.model end
    if callback then callback(result, err) end
  end)
end

local function remember(buf, set)
  local old = state.remembered[buf]
  if old and old ~= set and old ~= state.ask then target.release(old) end
  state.remembered[buf] = set
end

function M.invoke(operation, source)
  if not options then M.setup({}) end
  local buf, origin, mode = api.nvim_get_current_buf(), api.nvim_get_current_win(), api.nvim_get_mode().mode
  local visual = mode == 'v' or mode == 'V' or mode:sub(1, 1) == '\22'
  local set, err
  if visual then
    set, err = target.capture(buf, mode)
    api.nvim_feedkeys(api.nvim_replace_termcodes('<Esc>', true, false, true), 'nx', false)
  elseif operation == 'generate' then set = target.insertion(buf)
  elseif operation == 'replace' then set = state.remembered[buf]
  elseif source == 'previous' then set = state.ask
  elseif source == 'mapping' and state.last_action == 'ask' and state.ask and state.ask.buf == buf and target.valid(state.ask) then set = state.ask end
  if operation == 'replace' or source == 'previous' or visual then
    if not set or set.buf ~= buf or not target.valid(set) then notify(err or 'A valid selection in this buffer is needed', true); return end
  end
  if set then target.highlight(set, true) end
  local submitted = false
  state.prompt = ui.prompt(operation, state.model, origin, function(instruction)
    if state.busy or rpc.busy() then notify('Conversation busy; draft retained'); return false end
    local payload = { operation = operation, instruction = instruction, epoch = state.epoch,
      strict_budget = options.budget_mode ~= 'conservative' }
    if set then
      local snapshot, why = target.snapshot(set)
      if not snapshot then notify(why, true); return false end
      payload.targets, payload.block = snapshot, set.block or false
      payload.document = { id = 'buffer-' .. buf, filetype = vim.bo[buf].filetype,
        revision = 'r' .. api.nvim_buf_get_changedtick(buf),
        text = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), '\n') .. (vim.bo[buf].endofline and '\n' or '') }
      payload.whole_file = #snapshot == 1 and snapshot[1].start[1] == 0 and snapshot[1].start[2] == 0
        and snapshot[1]['end'][1] == api.nvim_buf_line_count(buf) - 1
        and snapshot[1]['end'][2] == #(api.nvim_buf_get_lines(buf, -2, -1, false)[1] or '')
    end
    state.last_action = operation
    if operation == 'ask' then state.ask = set
    else state.ask = nil end
    if operation == 'replace' or (operation == 'ask' and set) then remember(buf, set) end
    state.busy, submitted = true, true
    local epoch = state.epoch
    local result = ui.result(operation .. ' · starting', origin)
    state.result = result
    result.set('Waiting for backend…')
    rpc.request('turn', payload, function(response, failure)
      state.busy = false
      if epoch ~= state.epoch then result.title('canceled · result not applied'); return end
      if failure then
        result.title('request failed · source unchanged')
        result.set((state.partial or '') .. '\n\n' .. failure)
        return
      end
      if response.info and response.info.config then state.model = response.info.config.model end
      if operation == 'ask' then result.set(response.text); result.title('answer'); return end
      if response.status == 'needs_input' then result.set(response.message); result.title('clarification · source unchanged'); return end
      if operation == 'generate' and response.replacements[1].text == '' then
        result.set(response.raw)
        result.title('generate · completed without inserting text')
        target.release(set)
        return
      end
      local next_set, why = target.apply(set, response.replacements)
      if next_set then
        remember(buf, next_set)
        result.set(response.raw)
        result.title(operation .. ' · applied · one undo')
        if operation == 'generate' then state.ask = nil end
      else
        result.title('not applied · source changed')
        result.set(why .. '\n\n' .. response.raw)
      end
    end, function(event)
      if event.epoch ~= state.epoch then return end
      if event.kind == 'partial' then state.partial = event.text; result.set(event.text)
      elseif event.kind == 'status' then result.title(operation .. ' · ' .. event.text) end
    end)
    state.partial = nil
    return true
  end, function()
    target.highlight(set, false)
    if not submitted and visual then target.release(set) end
    if not submitted and operation == 'generate' then target.release(set) end
    state.prompt = nil
  end)
end

function M.cancel()
  state.epoch = state.epoch + 1
  request('cancel')
end

local function model_picker()
  request('models', {}, function(models)
    if not models then return end
    if #models == 0 then notify('Runtime did not announce models. Use :NvClaude model manual'); return end
    vim.ui.select(models, { prompt = 'Model', format_item = function(m) return m.displayName .. ' · ' .. m.value end }, function(model)
      if not model then return end
      local function budget(effort)
        local choices = { 'model default' }
        for _, n in ipairs(limits) do choices[#choices + 1] = n .. 'k' end
        vim.ui.select(choices, { prompt = 'Local context budget' }, function(choice)
          if not choice then return end
          request('configure', { model = model.value, effort = effort or false,
            context_limit_tokens = choice == 'model default' and vim.NIL or tonumber(choice:sub(1, -2)) * 1000 })
        end)
      end
      if model.supportsEffort and model.supportedEffortLevels and #model.supportedEffortLevels > 0 then
        vim.ui.select(model.supportedEffortLevels, { prompt = 'Effort' }, function(effort) if effort then budget(effort) end end)
      else budget(nil) end
    end)
  end)
end

function M.command(args)
  local command, argument = args:match('^(%S+)%s*(.-)$')
  command = command or 'ask'
  if command == 'ask' then M.invoke('ask', argument == 'previous' and 'previous' or 'general')
  elseif command == 'replace' or command == 'generate' then M.invoke(command)
  elseif command == 'cancel' then M.cancel()
  elseif command == 'result' then if state.result then state.result.show() end
  elseif command == 'new' or command == 'clear' then
    state.epoch = state.epoch + 1
    state.ask, state.last_action = nil, nil
    request(command)
  elseif command == 'info' then
    request('info', {}, function(info)
      if info then local view = ui.result('conversation info', api.nvim_get_current_win()); view.set(vim.inspect(info)); view.show() end
    end)
  elseif command == 'list' then
    request('list', {}, function(items)
      if not items then return end
      vim.ui.select(items, { prompt = 'Saved conversations', format_item = function(item)
        return os.date('%y:%m:%d:%H:%M:%S', item.created) .. ' - ' .. item.first_prompt:sub(1, 60):gsub('\n', ' ') .. ' [' .. item.id:sub(1, 8) .. ']'
      end }, function(item)
        if not item then return end
        state.epoch = state.epoch + 1
        state.ask, state.last_action = nil, nil
        request('resume', { id = item.id })
      end)
    end)
  elseif command == 'model' then
    if argument == '' then model_picker()
    elseif argument == 'manual' then
      vim.ui.input({ prompt = 'Model expression: ', default = state.model }, function(expression)
        if expression then request('configure', { expression = expression }) end
      end)
    else request('configure', { expression = argument }) end
  elseif command == 'sticky' then
    if argument ~= '' and argument ~= 'on' and argument ~= 'off' then notify('Use sticky on or off', true); return end
    request('sticky', argument == '' and {} or { enabled = argument == 'on' })
  elseif command == 'watermarks' then request('watermarks', { policy = argument })
  elseif command == 'system' then
    if argument == 'default' then request('system', {}, function(result) if result then rpc.system = table.concat(vim.fn.readfile(rpc.root .. '/resources/system.txt'), '\n') end end)
    elseif argument == 'modify' then
      request('info', {}, function(info)
        if not info then return end
        ui.system(rpc.system, function(text, done)
          request('system', { text = text }, function(result) if result then rpc.system = text end; done(result ~= nil) end)
        end)
      end)
    else notify('Use system modify or system default', true) end
  elseif command == 'login' then
    if state.busy then notify('Cancel the active request before login', true); return end
    rpc.stop()
    vim.cmd('botright new')
    vim.fn.jobstart(rpc.command('--login'), { term = true })
    vim.cmd('startinsert')
  elseif command == 'update' then
    if state.busy then notify('Cancel the active request before updating', true); return end
    rpc.stop()
    vim.fn.jobstart(rpc.command('--update'), {
      on_stderr = function(_, data) for _, line in ipairs(data) do if line ~= '' then notify(line) end end end,
      on_exit = function(_, code) notify(code == 0 and 'SDK updated; next request starts the new runtime' or 'SDK update failed', code ~= 0) end,
    })
  elseif command == 'save' or command == 'compact' then request(command)
  else notify('Unknown command: ' .. command, true) end
end

function M.setup(opts)
  opts = opts or {}
  options = vim.tbl_extend('force', {
    data_dir = vim.fn.stdpath('data') .. '/nvim-claude', state_dir = vim.fn.stdpath('state') .. '/nvim-claude',
    python = 'python3', billing = 'subscription', budget_mode = 'strict',
    model_config = { model = 'claude-haiku-5-5', effort = 'low', context_limit_tokens = 100000 },
  }, opts)
  state.model = options.model_config.model or 'claude-haiku-5-5'
  rpc.setup(options)
  api.nvim_create_user_command('NvClaude', function(command) M.command(command.args) end, {
    nargs = '*', force = true, range = true,
    complete = function(lead) return vim.tbl_filter(function(c) return c:sub(1, #lead) == lead end, commands) end,
  })
  for _, mapping in ipairs(state.maps) do
    local found = vim.fn.maparg(mapping.key, mapping.mode, false, true)
    if found.callback == mapping.callback then pcall(vim.keymap.del, mapping.mode, mapping.key) end
  end
  state.maps = {}
  if opts.keys ~= false then
    for action, default in pairs(defaults) do
      local explicit = opts.keys and opts.keys[action] ~= nil
      local key = explicit and opts.keys[action] or default[1]
      if explicit and opts.keys[action] == false then key = false end
      if key then
        for _, mode in ipairs(default[2]) do
          if explicit or vim.fn.maparg(key, mode) == '' then
            local callback = function()
              if action == 'replace' or action == 'replace_short' then M.invoke('replace', 'mapping')
              elseif action == 'ask' then M.invoke('ask', 'mapping')
              elseif action == 'generate' or action == 'generate_insert' then M.invoke('generate', 'mapping')
              elseif action == 'model_manual' then M.command('model manual')
              else M.command(action) end
            end
            vim.keymap.set(mode, key, callback, { silent = true, desc = 'Claude ' .. action })
            state.maps[#state.maps + 1] = { key = key, mode = mode, callback = callback }
          end
        end
      end
    end
  end
  local group = api.nvim_create_augroup('nvim-claude', { clear = true })
  api.nvim_create_autocmd('VimLeavePre', { group = group, callback = rpc.stop })
  api.nvim_create_autocmd('BufEnter', { group = group, callback = function(event)
    if state.ask and event.buf ~= state.ask.buf and vim.bo[event.buf].buftype == '' then
      state.ask, state.last_action = nil, nil
    end
  end })
end

return M
