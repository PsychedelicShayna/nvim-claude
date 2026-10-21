local M = {}
local opts, process, installing, runtime, input = {}, nil, false, nil, ''
local serial, pending, waiting, events = 0, {}, {}, nil
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':h:h:h')
local stopping, ready = false, false

local function notify(text, level)
  vim.notify('nvim-claude: ' .. text, level or vim.log.levels.INFO)
end

local function fail(message)
  local callbacks = pending
  pending = {}
  for _, callback in pairs(callbacks) do callback({ message = message }) end
  local queue = waiting
  waiting = {}
  for _, item in ipairs(queue) do item.callback({ message = message }) end
end

local function frame(value)
  local body = vim.json.encode(value)
  return 'Content-Length: ' .. #body .. '\r\n\r\n' .. body
end

local function transmit(id, method, params, callback)
  pending[id] = callback
  local ok = pcall(vim.fn.chansend, process, frame({ jsonrpc = '2.0', id = id, method = method, params = params }))
  if not ok then
    pending[id] = nil
    callback({ message = 'Bridge input closed' })
  end
end

local function receive(data)
  input = input .. table.concat(data, '\n')
  while true do
    local start, finish = input:find('\r\n\r\n', 1, true)
    if not start then return end
    local size = tonumber(input:sub(1, start - 1):lower():match('content%-length:%s*(%d+)'))
    if not size or size > 32 * 1024 * 1024 then
      fail('Invalid bridge protocol frame')
      M.stop()
      return
    end
    if #input < finish + size then return end
    local body = input:sub(finish + 1, finish + size)
    input = input:sub(finish + size + 1)
    local ok, message = pcall(vim.json.decode, body)
    if not ok then fail('Invalid JSON from bridge'); M.stop(); return end
    if message.method == 'event' then
      if events then events(message.params) end
    elseif message.id and pending[message.id] then
      local callback = pending[message.id]
      pending[message.id] = nil
      callback(message.error, message.result)
    end
  end
end

local function configuration()
  local result = {}
  for _, key in ipairs({ 'model', 'effort', 'context_limit_tokens', 'thinking', 'auth_mode' }) do
    if opts[key] ~= nil then result[key] = opts[key] end
  end
  return result
end

local function launch()
  input, stopping, ready = '', false, false
  local stderr = {}
  local job
  job = vim.fn.jobstart({ runtime.python, root .. '/python/bridge.py', '--state', opts.state_dir or (vim.fn.stdpath('state') .. '/nvim-claude/conversations') }, {
    on_stdout = function(_, data) receive(data) end,
    on_stderr = function(_, data)
      for _, line in ipairs(data) do if line ~= '' then stderr[#stderr + 1] = line end end
      if #stderr > 40 then table.remove(stderr, 1) end
    end,
    on_exit = function(_, code)
      if process ~= job then return end
      process, ready = nil, false
      if not stopping then
        fail('Bridge exited (' .. code .. '): ' .. table.concat(stderr, '\n'))
      end
    end,
  })
  if job <= 0 then fail('Cannot launch Python bridge'); return end
  process = job
  serial = serial + 1
  transmit(serial, 'initialize', configuration(), function(err, result)
    if err then
      fail(err.message or tostring(err))
      M.stop()
      return
    end
    ready = true
    local queue = waiting
    waiting = {}
    for _, item in ipairs(queue) do
      if item.method == 'initialize' then item.callback(nil, result)
      else transmit(item.id, item.method, item.params, item.callback) end
    end
  end)
end

local function provision(update, callback)
  if installing then return end
  installing = true
  local python = opts.python or vim.fn.exepath('python3')
  if python == '' then python = vim.fn.exepath('python') end
  if python == '' then installing = false; fail('Python 3.10+ was not found; set opts.python'); return end
  local argv = { python, root .. '/python/provision.py', '--root', opts.data_dir or (vim.fn.stdpath('data') .. '/nvim-claude') }
  if update then argv[#argv + 1] = '--update' end
  notify('Preparing SDK runtime asynchronously...')
  local diagnostics = ''
  vim.system(argv, { text = true, stderr = function(_, data)
    if data then diagnostics = (diagnostics .. data):sub(-8192) end
    if data and (data:find('Creating Python') or data:find('Installing latest')) then
      vim.schedule(function() notify(vim.trim(data)) end)
    end
  end }, vim.schedule_wrap(function(result)
    installing = false
    if result.code ~= 0 then
      local error = diagnostics ~= '' and diagnostics or 'Python venv/pip installation failed. Check network and run :NvClaude update.'
      fail(error)
      if callback then callback({ message = error }) end
      return
    end
    local ok, value = pcall(vim.json.decode, result.stdout)
    if not ok then fail('Provisioner returned invalid runtime metadata'); return end
    runtime = value
    if callback then callback(nil, value) else launch() end
  end))
end

function M.request(method, params, callback)
  callback = callback or function(err) if err then notify(err.message or tostring(err), vim.log.levels.ERROR) end end
  params = params or {}
  serial = serial + 1
  local id = serial
  if method == 'update' then
    if installing then callback({ message = 'Provisioning already in progress' }); return id end
    M.stop()
    provision(true, callback)
    return id
  end
  if method == 'cancel' then
    local retained = {}
    for _, item in ipairs(waiting) do
      if item.method == 'turn' then item.callback({ message = 'Cancelled before dispatch' })
      else retained[#retained + 1] = item end
    end
    waiting = retained
    if process then transmit(id, method, params, callback)
    else callback(nil, { cancelled = true }) end
    return id
  end
  if process and ready then transmit(id, method, params, callback)
  else
    waiting[#waiting + 1] = { id = id, method = method, params = params, callback = callback }
    if not installing and not process then
      if runtime then launch() else provision(false) end
    end
  end
  return id
end

function M.login()
  local function open(err)
    if err then notify(err.message or tostring(err), vim.log.levels.ERROR); return end
    vim.cmd('botright new')
    vim.fn.jobstart({ runtime.cli, 'auth', 'login' }, { term = true })
    vim.cmd('startinsert')
  end
  if runtime then open() else provision(false, open) end
end

function M.setup(config)
  opts = config or {}
  local group = vim.api.nvim_create_augroup('NvClaudeRPC', { clear = true })
  vim.api.nvim_create_autocmd('VimLeavePre', { group = group, callback = M.stop })
end

function M.on_event(callback) events = callback end

function M.stop()
  ready = false
  if process then
    stopping = true
    local old = process
    process = nil
    pcall(vim.fn.chanclose, old, 'stdin')
    -- Give the actor time to interrupt and remove unsaved owned sessions.
    vim.defer_fn(function() pcall(vim.fn.jobstop, old) end, 1500)
  end
  fail('Bridge stopped; no edit applied')
end

return M
