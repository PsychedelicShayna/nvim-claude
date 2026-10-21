local M = {}
local api = vim.api
local targets = require('nvim-claude.targets')
local runtime = require('nvim-claude.runtime')
local ui = require('nvim-claude.ui')
local state = { remembered = {}, mappings = {}, config = { model = 'claude-haiku-5-5' } }
local commands = { 'ask', 'replace', 'generate', 'model', 'clear', 'new', 'sticky', 'save', 'info',
  'list', 'compact', 'cancel', 'watermarks', 'system', 'setup', 'login', 'result' }
local defaults = {
  replace = { '<leader>cc', { 'n', 'x' } }, replace_short = { '<leader>c', { 'n', 'x' } },
  ask = { '<leader>ca', { 'n', 'x' } }, generate = { '<leader>ci', { 'n' } },
  generate_insert = { false, { 'i' } }, model = { '<leader>cm', { 'n' } },
  model_manual = { '<leader>cM', { 'n' } }, clear = { '<leader>cC', { 'n' } },
  new = { '<leader>cn', { 'n' } }, sticky = { '<leader>cS', { 'n' } },
  save = { '<leader>cs', { 'n' } }, info = { '<leader>cx', { 'n' } }, list = { '<leader>cl', { 'n' } },
}
local function notify(message, error)
  vim.notify(message, error and vim.log.levels.ERROR or vim.log.levels.INFO, { title = 'nvim-claude' })
end
local function remember(buf, target)
  if state.remembered[buf] ~= target then targets.release(state.remembered[buf]) end
  state.remembered[buf] = target
end
local function display(title, value)
  local view = ui.result(title, api.nvim_get_current_win(), true)
  view.set(type(value) == 'string' and value or vim.inspect(value))
  view.show()
  state.result = view
end
local function request(method, params, callback)
  runtime.request(method, params, callback or function(result, err)
    if err then notify(err, true) else notify(vim.inspect(result)) end
  end)
end

runtime.on_event = function(event)
  local active = state.active
  if not active or active.epoch ~= event.epoch or event.epoch ~= runtime.epoch then return end
  if event.kind == 'text' then active.view.append(event.text)
  elseif event.kind == 'status' then active.view.status(event.status)
  elseif event.kind == 'budget_violation' then active.view.status('runtime budget violation') end
end

function M.invoke(operation, selected)
  local origin, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
  local mode = vim.fn.mode()
  local visual = mode == 'v' or mode == 'V' or mode:sub(1, 1) == '\22'
  local target, err
  if visual then
    local ok, value = pcall(targets.visual)
    if not ok then notify(tostring(value), true); return end
    target = value
    api.nvim_feedkeys(vim.keycode('<Esc>'), 'nx', false)
  elseif operation == 'generate' then
    target = targets.insertion()
  elseif operation == 'replace' then
    target, err = targets.clone(state.remembered[buf])
  elseif selected == 'previous' then
    if state.ask_chain and state.ask_chain.buf == buf then target, err = targets.clone(state.ask_chain.target)
    else err = 'There is no selected-ask target in this buffer' end
  elseif selected == 'mapping' and state.ask_chain and state.ask_chain.buf == buf then
    target = targets.clone(state.ask_chain.target)
  end
  if (operation == 'replace' or selected == 'previous') and not target then
    notify(err or 'Select text before replacing it', true); return
  end
  if operation == 'generate' and visual then operation = 'replace' end
  local captured = target
  ui.prompt(operation, state.config.model, origin, function(instruction)
    if state.active then notify('Conversation busy; your draft is retained', true); return false end
    local envelope
    if captured then
      envelope, err = targets.envelope(captured)
      if not envelope then notify(err, true); return false end
    end
    local payload = { operation = operation, instruction = instruction, epoch = runtime.epoch }
    if captured then
      payload.document = { id = 'buffer-' .. buf, filetype = vim.bo[buf].filetype, path = api.nvim_buf_get_name(buf) }
      payload.buffer_text = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
      if vim.bo[buf].endofline then payload.buffer_text = payload.buffer_text .. '\n' end
      payload.targets = envelope
      payload.source_revision = api.nvim_buf_get_changedtick(buf)
      local p = captured.parts[1]
      local last = api.nvim_buf_line_count(buf) - 1
      payload.whole_document = #captured.parts == 1 and p.start[1] == 0 and p.start[2] == 0
        and p.finish[1] == last and p.finish[2] == #(api.nvim_buf_get_lines(buf, last, last + 1, false)[1] or '')
      remember(buf, targets.clone(captured))
    end
    if operation == 'ask' and captured then
      state.ask_chain = { buf = buf, target = state.remembered[buf] }
    else state.ask_chain = nil end
    local view = ui.result(operation .. ' · ' .. state.config.model, origin)
    view.status('starting')
    state.result = view
    local active = { target = captured, view = view, epoch = runtime.epoch }
    state.active = active
    request('turn', payload, function(result, failure)
      state.active = nil
      if active.epoch ~= runtime.epoch then
        view.status('canceled; no edit')
      elseif failure then
        view.status('failed; no edit')
        view.set(view.text .. '\n\nError: ' .. failure)
        notify(failure, true)
      elseif operation == 'ask' then
        view.set(result.text)
        view.status('complete')
      else
        local edit = result.edit
        if edit.status == 'needs_input' then
          view.set(edit.message); view.status('needs input; no edit')
        else
          local updated, reason = targets.apply(captured, edit.replacements)
          if updated then
            remember(buf, updated)
            view.set(table.concat(vim.tbl_map(function(r) return r.text end, edit.replacements), '\n'))
            view.status('applied; :NvClaude result to inspect')
            if api.nvim_win_is_valid(view.win) then api.nvim_win_close(view.win, true) end
            notify(operation .. ' applied' .. (view.text == '' and ' (empty result)' or ''))
          else
            view.set('Not applied: ' .. reason .. '\n\n' .. result.raw)
            view.status('target changed; result retained')
            notify(reason .. '; use :NvClaude result', true)
          end
        end
      end
      targets.release(captured)
      if state.after_turn then local action = state.after_turn; state.after_turn = nil; vim.schedule(action) end
    end)
    return true
  end, function() targets.release(captured) end)
end

local function transition(action)
  if state.active then
    state.after_turn = action
    runtime.cancel()
  else action() end
end

local function configure(params)
  request('configure', params, function(result, err)
    if err then notify(err, true) else state.config = result; notify('Model: ' .. result.model) end
  end)
end
function M.model(manual)
  if manual then
    vim.ui.input({ prompt = 'Model expression: ', default = state.config.model }, function(value)
      if value and value ~= '' then transition(function() configure({ expression = value }) end) end
    end)
    return
  end
  request('models', {}, function(result, err)
    if err then notify(err, true); return end
    if #result.models == 0 then notify('Runtime did not announce models. Use :NvClaude model manual', true); return end
    vim.ui.select(result.models, { prompt = 'Runtime models', format_item = function(m)
      return (m.displayName or m.value) .. ' · ' .. m.value .. (m.resolvedModel and ' → ' .. m.resolvedModel or '')
    end }, function(model)
      if not model then return end
      local function limit(effort)
        local choices = { { label = 'model default', value = false } }
        for _, count in ipairs(result.presets) do choices[#choices + 1] = { label = count .. 'k', value = count * 1000 } end
        vim.ui.select(choices, { prompt = 'Local prompt ceiling', format_item = function(c) return c.label end }, function(choice)
          if not choice then return end
          transition(function() configure({ model = model.value, effort = effort or vim.NIL,
            context_limit_tokens = choice.value or vim.NIL }) end)
        end)
      end
      if model.supportsEffort and model.supportedEffortLevels and #model.supportedEffortLevels > 0 then
        vim.ui.select(model.supportedEffortLevels, { prompt = 'Effort' }, function(effort) if effort then limit(effort) end end)
      else limit(nil) end
    end)
  end)
end

local function system_prompt(action)
  if action == 'default' then
    if state.active then notify('Wait for or cancel the active request before changing the system prompt', true); return end
    state.system = nil; request('system', {}); return
  end
  if action ~= 'modify' then notify('Use system modify or system default', true); return end
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'text'
  api.nvim_buf_set_name(buf, 'nvclaude://system/' .. buf)
  local lines = state.system and vim.split(state.system, '\n', { plain = true })
    or vim.fn.readfile(runtime.root .. '/prompts/system.txt')
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.cmd('new')
  api.nvim_win_set_buf(0, buf)
  api.nvim_create_autocmd('BufWriteCmd', { buffer = buf, callback = function()
    if state.active then notify('Conversation busy; prompt draft retained', true); return end
    local text = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
    if text == '' then notify('System prompt cannot be empty', true); return end
    request('system', { text = text }, function(_, err)
      if err then notify(err, true) else state.system = text; vim.bo[buf].modified = false; notify('System prompt updated for the next turn') end
    end)
  end })
end

function M.command(args)
  local action, arg = args[1] or 'replace', args[2]
  if action == 'ask' then M.invoke('ask', arg)
  elseif action == 'replace' or action == 'generate' then M.invoke(action)
  elseif action == 'model' then M.model(arg == 'manual')
  elseif action == 'cancel' then runtime.cancel(); notify('Cancellation requested')
  elseif action == 'new' or action == 'clear' then
    transition(function() state.ask_chain = nil; request(action, { epoch = runtime.epoch }) end)
  elseif action == 'sticky' then
    if arg and arg ~= 'on' and arg ~= 'off' then notify('Use sticky on or sticky off', true); return end
    request('sticky', arg and { enabled = arg == 'on' } or {})
  elseif action == 'save' then request('save', {})
  elseif action == 'compact' then transition(function() request('compact', {}) end)
  elseif action == 'info' then request('info', {}, function(result, err)
    if err then notify(err, true) else display('Conversation info', result) end
  end)
  elseif action == 'list' then request('list', {}, function(result, err)
    if err then notify(err, true); return end
    vim.ui.select(result, { prompt = 'Saved conversations', format_item = function(c) return c.title .. ' [' .. c.id:sub(1, 8) .. ']' end }, function(choice)
      if choice then transition(function()
        state.ask_chain = nil
        request('resume', { id = choice.id }, function(value, failure)
          if failure then notify(failure, true) else state.config = value.config; notify('Conversation resumed') end
        end)
      end) end
    end)
  end)
  elseif action == 'watermarks' then request('watermarks', { mode = arg or 'allow', map = state.opts.punctuation_map })
  elseif action == 'system' then system_prompt(arg)
  elseif action == 'result' then if state.result then state.result.show() else notify('No result yet') end
  elseif action == 'setup' then
    if runtime.job then notify('Restart Neovim before explicitly updating the environment', true)
    else runtime.start(arg == 'update') end
  elseif action == 'login' then request('login', {}, function(result, err)
    if err then notify(err, true); return end
    vim.cmd('botright new')
    vim.fn.jobstart(result.argv, { term = true })
    vim.cmd('startinsert')
  end)
  else notify('Unknown command: ' .. action, true) end
end

function M.setup(opts)
  opts = opts or {}
  if vim.fn.has('nvim-0.11') ~= 1 then error('nvim-claude requires Neovim 0.11 or later') end
  state.opts = opts
  state.config.model = opts.model or state.config.model
  runtime.configure(opts)
  api.nvim_set_hl(0, 'NvClaudeTarget', { link = 'Visual', default = true })
  for _, mapping in ipairs(state.mappings) do
    local existing = vim.fn.maparg(mapping.lhs, mapping.mode, false, true)
    if existing.callback == mapping.callback then pcall(vim.keymap.del, mapping.mode, mapping.lhs) end
  end
  state.mappings = {}
  api.nvim_create_user_command('NvClaude', function(command) M.command(command.fargs) end, {
    nargs = '*', range = true, force = true,
    complete = function(lead, line)
      local candidates = commands
      if line:match('NvClaude%s+ask%s+') then candidates = { 'previous' }
      elseif line:match('NvClaude%s+model%s+') then candidates = { 'manual' }
      elseif line:match('NvClaude%s+system%s+') then candidates = { 'modify', 'default' }
      elseif line:match('NvClaude%s+watermarks%s+') then candidates = { 'allow', 'remove', 'replace' }
      elseif line:match('NvClaude%s+sticky%s+') then candidates = { 'on', 'off' }
      elseif line:match('NvClaude%s+setup%s+') then candidates = { 'update' } end
      return vim.tbl_filter(function(c) return c:sub(1, #lead) == lead end, candidates)
    end,
  })
  if opts.keys ~= false then
    local keys = opts.keys or {}
    for action, spec in pairs(defaults) do
      local lhs = keys[action]
      local explicit = lhs ~= nil
      if lhs == nil then lhs = spec[1] end
      if lhs then
        for _, mode in ipairs(spec[2]) do
          local existing = vim.fn.maparg(lhs, mode, false, true)
          if explicit or vim.tbl_isempty(existing) then
            local callback = function()
              if action == 'ask' then M.invoke('ask', 'mapping')
              elseif action == 'replace' or action == 'replace_short' then M.invoke('replace')
              elseif action == 'generate' or action == 'generate_insert' then M.invoke('generate')
              elseif action == 'model_manual' then M.model(true)
              else M.command({ action }) end
            end
            vim.keymap.set(mode, lhs, callback, { silent = true, desc = 'NvClaude ' .. action })
            state.mappings[#state.mappings + 1] = { lhs = lhs, mode = mode, callback = callback }
          end
        end
      end
    end
  end
  local group = api.nvim_create_augroup('NvClaude', { clear = true })
  api.nvim_create_autocmd('VimLeavePre', { group = group, callback = function()
    runtime.stop()
    if runtime.job then vim.fn.jobwait({ runtime.job }, 3000) end
  end })
  api.nvim_create_autocmd('BufDelete', { group = group, callback = function(event)
    targets.release(state.remembered[event.buf]); state.remembered[event.buf] = nil
    if state.ask_chain and state.ask_chain.buf == event.buf then state.ask_chain = nil end
  end })
end

return M
