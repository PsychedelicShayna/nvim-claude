local M = { callbacks = {}, next_id = 0, pending = {}, buffer = '', state = 'stopped' }
local api = vim.api
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2))))
local function notify(text, level) vim.notify('NvClaude: ' .. text, level or vim.log.levels.INFO) end

local function fail(message)
  M.state = 'stopped'
  M.job = nil
  M.buffer = ''
  local callbacks, pending = M.callbacks, M.pending
  M.callbacks, M.pending = {}, {}
  for _, cb in pairs(callbacks) do cb(nil, message) end
  for _, item in ipairs(pending) do item.cb(nil, message) end
end

local function frames(data)
  M.buffer = M.buffer .. table.concat(data, '\n')
  while true do
    local boundary = M.buffer:find('\r\n\r\n', 1, true)
    if not boundary then return end
    local length = tonumber(M.buffer:sub(1, boundary - 1):match('[Cc]ontent%-[Ll]ength:%s*(%d+)'))
    if not length or length > 32 * 1024 * 1024 then
      notify('Invalid bridge frame', vim.log.levels.ERROR)
      if M.job then vim.fn.jobstop(M.job) end
      return
    end
    local start = boundary + 4
    if #M.buffer < start + length - 1 then return end
    local raw = M.buffer:sub(start, start + length - 1)
    M.buffer = M.buffer:sub(start + length)
    local ok, message = pcall(vim.json.decode, raw)
    if not ok then fail('Invalid bridge JSON'); return end
    if message.id and M.callbacks[message.id] then
      local cb = M.callbacks[message.id]
      M.callbacks[message.id] = nil
      cb(message.result, message.error and message.error.message)
    elseif message.method and M.on_event then
      M.on_event(message.method, message.params)
    end
  end
end

local function send(method, params, cb)
  M.next_id = M.next_id + 1
  M.callbacks[M.next_id] = cb
  local payload = vim.json.encode({ jsonrpc = '2.0', id = M.next_id, method = method, params = params })
  vim.fn.chansend(M.job, 'Content-Length: ' .. #payload .. '\r\n\r\n' .. payload)
end

local function start()
  M.state = 'starting'
  M.job = vim.fn.jobstart({ M.data .. '/venv/bin/python', root .. '/python/bridge.py', M.sessions }, {
    detach = true,
    on_stdout = function(_, data) frames(data) end,
    on_stderr = function(_, data)
      local text = table.concat(data, '\n')
      if text:match('%S') then M.last_diagnostic = text:sub(-4096) end
    end,
    on_exit = function(_, code)
      fail('Bridge exited (' .. code .. ')' .. (M.last_diagnostic and ': ' .. M.last_diagnostic or ''))
    end,
  })
  if M.job <= 0 then fail('Could not start Python bridge'); return end
  send('initialize', { config = M.config, punctuation = M.punctuation, auth = M.auth }, function(result, err)
    if err then fail(err); return end
    M.state, M.info = 'ready', result
    local pending = M.pending
    M.pending = {}
    for _, item in ipairs(pending) do send(item.method, item.params, item.cb) end
  end)
end

function M.setup(opts, on_event)
  M.data = vim.fn.stdpath('data') .. '/nvim-claude'
  M.sessions = vim.fn.stdpath('state') .. '/nvim-claude/sessions'
  M.python = opts.python or 'python3'
  M.auth = opts.auth or 'runtime'
  M.config = { model = opts.model or 'claude-haiku-5-5', effort = opts.effort == false and vim.NIL or opts.effort or 'low',
    context_limit_tokens = opts.context_limit_tokens == false and vim.NIL or opts.context_limit_tokens or 100000 }
  M.punctuation = opts.punctuation
  M.on_event = on_event
end

function M.provision(update, cb)
  if M.state == 'installing' then cb(nil, 'SDK installation is already running'); return end
  M.state = 'installing'
  notify('Preparing the plugin SDK environment asynchronously')
  local args = { M.python, root .. '/python/provision.py', M.data }
  if update then args[#args + 1] = '--update' end
  local output = {}
  M.installer = vim.fn.jobstart(args, {
    on_stdout = function(_, data)
      for _, line in ipairs(data) do
        if line ~= '' then output[#output + 1] = line end
        if line:match('^Creating plugin') or line:match('^Installing latest') then notify(line) end
      end
    end,
    on_stderr = function(_, data)
      for _, line in ipairs(data) do if line ~= '' then output[#output + 1] = line end end
    end,
    on_exit = function(_, code)
      M.installer = nil
      if code ~= 0 then
        local err = 'SDK setup failed. Check Python 3.10+, venv, pip, and network access.\n' .. table.concat(output, '\n')
        fail(err); cb(nil, err); return
      end
      M.state = 'stopped'
      notify('SDK environment ready')
      cb(true)
    end,
  })
  if M.installer <= 0 then M.installer = nil; fail('Cannot start Python installer'); cb(nil, 'Python interpreter not executable') end
end

function M.request(method, params, cb)
  cb = cb or function(result, err)
    if err then notify(err, vim.log.levels.ERROR) elseif result and result.message then notify(result.message) end
  end
  if M.state == 'ready' then send(method, params or {}, cb); return end
  M.pending[#M.pending + 1] = { method = method, params = params or {}, cb = cb }
  if M.state == 'starting' or M.state == 'installing' then return end
  if vim.uv.fs_stat(M.data .. '/ready.json') and vim.uv.fs_stat(M.data .. '/venv/bin/python') then start()
  else M.provision(false, function(ok) if ok then start() end end) end
end

function M.stop()
  if M.job then
    -- EOF lets the bridge interrupt its SDK child and release exact session leases.
    pcall(vim.fn.chanclose, M.job, 'stdin')
  end
end

function M.resource() return root .. '/resources/system.txt' end
return M
