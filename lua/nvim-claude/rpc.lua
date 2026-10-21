local M = { pending = {}, serial = 0 }
local buffer, channel, options, initializing = '', nil, nil, false
local queued = {}
local root = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/lua/nvim%-claude/rpc.lua$')
M.root = root
local function notify(message, level) vim.notify('nvim-claude: ' .. message, level or vim.log.levels.INFO) end

local function fail(message)
  channel, initializing, buffer = nil, false, ''
  local pending = M.pending
  M.pending = {}
  for _, request in pairs(pending) do request.callback(nil, message) end
  local waiters = queued
  queued = {}
  for _, fn in ipairs(waiters) do fn(message) end
end

local function receive(chunk)
  buffer = buffer .. chunk
  while true do
    local start, finish = buffer:find('\r\n\r\n', 1, true)
    if not start then return end
    local length = tonumber(buffer:sub(1, start - 1):match('[Cc]ontent%-[Ll]ength:%s*(%d+)'))
    if not length or length > 16777216 then fail('Invalid bridge frame'); return end
    if #buffer < finish + length then return end
    local raw = buffer:sub(finish + 1, finish + length)
    buffer = buffer:sub(finish + length + 1)
    local ok, message = pcall(vim.json.decode, raw)
    if not ok then fail('Invalid bridge JSON'); return end
    if message.method == 'event' then
      local request = M.pending[message.params.id]
      if request and request.event then request.event(message.params) end
    elseif message.id then
      local request = M.pending[message.id]
      M.pending[message.id] = nil
      if request then request.callback(message.result, message.error and message.error.message) end
    end
  end
end

local function send(method, params, callback, event)
  M.serial = M.serial + 1
  local id = M.serial
  M.pending[id] = { callback = callback, event = event }
  local data = vim.json.encode({ jsonrpc = '2.0', id = id, method = method, params = params or {} })
  local ok = pcall(vim.fn.chansend, channel, 'Content-Length: ' .. #data .. '\r\n\r\n' .. data)
  if not ok then fail('Bridge closed') end
  return id
end

function M.setup(opts) options = opts end

function M.command(extra)
  local argv = { options.python or 'python3', root .. '/python/bootstrap.py', '--data', options.data_dir,
    '--state', options.state_dir }
  if extra then argv[#argv + 1] = extra end
  return argv
end

local function start(callback)
  if channel and not initializing then callback(); return end
  queued[#queued + 1] = callback
  if initializing then return end
  initializing = true
  notify('Starting backend; first use may install the SDK')
  local diagnostics = {}
  channel = vim.fn.jobstart(M.command(), {
    on_stdout = function(_, data) receive(table.concat(data, '\n')) end,
    on_stderr = function(_, data)
      for _, line in ipairs(data) do
        if line ~= '' then
          diagnostics[#diagnostics + 1] = line
          if #diagnostics > 20 then table.remove(diagnostics, 1) end
          if line:match('^nvim%-claude:') then notify(line) end
        end
      end
    end,
    on_exit = function(_, code)
      if channel then fail('Backend exited (' .. code .. '): ' .. table.concat(diagnostics, '\n')) end
    end,
  })
  if channel <= 0 then fail('Cannot start Python; configure opts.python'); return end
  send('initialize', { config = options.model_config, billing = options.billing, budget_mode = options.budget_mode }, function(result, err)
    initializing = false
    if err then fail(err); return end
    M.system = result.system
    local waiters = queued
    queued = {}
    for _, fn in ipairs(waiters) do fn() end
  end)
end

function M.busy()
  return initializing or next(M.pending) ~= nil or #queued > 0
end

function M.request(method, params, callback, event)
  start(function(err)
    if err then callback(nil, err) else send(method, params, callback, event) end
  end)
end

function M.stop()
  if channel then
    local job = channel
    -- EOF lets the bridge interrupt, close the SDK and remove ephemeral records.
    pcall(vim.fn.chanclose, job, 'stdin')
    vim.fn.jobwait({ job }, 1500)
    if vim.fn.jobwait({ job }, 0)[1] == -1 then pcall(vim.fn.jobstop, job) end
  end
end

return M
