local uv = vim.uv
local M = {}
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':h:h:h')
local data = vim.fn.stdpath('data') .. '/nvim-claude'
local state = vim.fn.stdpath('state') .. '/nvim-claude'
local python = data .. '/venv/bin/python'
local pending, queue, next_id = {}, {}, 0
local input, output, errors, process, stopped
local buffer = ''
local booting, force_update = false, false
local on_event

local function notice(text, level)
  vim.schedule(function() vim.notify('nvim-claude: ' .. text, level or vim.log.levels.INFO) end)
end

local function fail(message)
  booting = false
  for id, callback in pairs(pending) do
    pending[id] = nil
    vim.schedule(function() callback(nil, message) end)
  end
  local old = queue
  queue = {}
  for _, item in ipairs(old) do
    vim.schedule(function() item.callback(nil, message) end)
  end
end

local function receive(chunk)
  buffer = buffer .. chunk
  while true do
    local split = buffer:find('\r\n\r\n', 1, true)
    if not split then return end
    local headers = buffer:sub(1, split - 1)
    local size = tonumber(headers:match('[Cc]ontent%-[Ll]ength:%s*(%d+)'))
    if not size or size > 16000000 then return fail('invalid bridge frame') end
    local start = split + 4
    if #buffer - start + 1 < size then return end
    local text = buffer:sub(start, start + size - 1)
    buffer = buffer:sub(start + size)
    local ok, message = pcall(vim.json.decode, text)
    if not ok then return fail('invalid bridge JSON: ' .. tostring(message)) end
    vim.schedule(function()
      if message.method == 'event' then
        if on_event then on_event(message.params) end
      elseif message.id and pending[message.id] then
        local callback = pending[message.id]
        pending[message.id] = nil
        if message.error then callback(nil, message.error.message) else callback(message.result) end
      end
    end)
  end
end

local function dispatch(method, params, callback)
  next_id = next_id + 1
  local id = next_id
  pending[id] = callback
  local body = vim.json.encode({ jsonrpc = '2.0', id = id, method = method, params = params or {} })
  input:write('Content-Length: ' .. #body .. '\r\n\r\n' .. body)
end

local function launch()
  vim.fn.mkdir(state, 'p')
  local stdin, stdout, stderr = uv.new_pipe(false), uv.new_pipe(false), uv.new_pipe(false)
  input, output, errors = stdin, stdout, stderr
  buffer = ''
  local handle, pid
  handle, pid = uv.spawn(python, {
    args = { root .. '/python/nvim_claude_bridge.py', state },
    stdio = { stdin, stdout, stderr },
  }, function(code, signal)
    if process == handle then process = nil end
    stdout:read_stop()
    stderr:read_stop()
    stdin:close()
    stdout:close()
    stderr:close()
    handle:close()
    if stopped == handle then stopped = nil else fail(('bridge exited (%s, signal %s)'):format(code, signal)) end
  end)
  if not handle then
    stdin:close(); stdout:close(); stderr:close()
    fail('could not start Python bridge: ' .. tostring(pid))
    return
  end
  process = handle
  stdout:read_start(function(err, bytes)
    if err then return fail('bridge stdout: ' .. err) end
    if bytes then receive(bytes) end
  end)
  stderr:read_start(function(_, bytes)
    if bytes and bytes:match('%S') then notice(bytes:gsub('%s+$', ''), vim.log.levels.WARN) end
  end)
  booting = false
  local waiting = queue
  queue = {}
  for _, item in ipairs(waiting) do dispatch(item.method, item.params, item.callback) end
end

local function command(argv, label, callback, on_failure)
  notice(label)
  vim.system(argv, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        if on_failure then on_failure() end
        fail(label .. ' failed: ' .. ((result.stderr or ''):sub(-1500)))
      else
        callback()
      end
    end)
  end)
end

local function provision()
  if not force_update and uv.fs_stat(python) and uv.fs_stat(data .. '/ready') then return launch() end
  vim.fn.mkdir(data, 'p')
  local lock = data .. '/install.lock'
  if not uv.fs_mkdir(lock, 448) then
    local owner = io.open(lock .. '/pid', 'r')
    if owner then
      local pid = tonumber(owner:read('*l'))
      owner:close()
      if pid and not uv.kill(pid, 0) then
        uv.fs_unlink(lock .. '/pid')
        uv.fs_rmdir(lock)
      end
    else
      local stat = uv.fs_stat(lock)
      if stat and os.time() - stat.mtime.sec > 30 then uv.fs_rmdir(lock) end
    end
    vim.defer_fn(function()
      if booting then provision() end
    end, 1200)
    return
  end
  local pidfile = assert(io.open(lock .. '/pid', 'w'))
  pidfile:write(tostring(uv.os_getpid()), '\n')
  pidfile:close()
  local function unlock()
    uv.fs_unlink(lock .. '/pid')
    uv.fs_rmdir(lock)
  end
  if force_update then uv.fs_unlink(data .. '/ready') end
  local system_python = M.python or vim.fn.exepath('python3')
  if system_python == '' then unlock(); return fail('Python 3.10+ is required; set opts.python') end
  local function install()
    local argv = { python, '-m', 'pip', 'install', '--disable-pip-version-check' }
    if force_update then argv[#argv + 1] = '--upgrade' end
    argv[#argv + 1] = 'claude-agent-sdk'
    command(argv, 'Installing latest Claude Agent SDK', function()
      local marker = io.open(data .. '/ready', 'w')
      if not marker then unlock(); return fail('could not mark SDK install ready') end
      marker:write('ready\n')
      marker:close()
      force_update = false
      unlock()
      launch()
    end, unlock)
  end
  if uv.fs_stat(python) then return install() end
  command({ system_python, '-c', 'import sys; assert sys.version_info >= (3, 10), \"Python 3.10+ required\"' },
    'Checking Python version', function()
      command({ system_python, '-m', 'venv', data .. '/venv' }, 'Creating Python environment', install, unlock)
    end, unlock)
end

function M.setup(options, callback)
  M.python = options.python
  on_event = callback
end

function M.call(method, params, callback)
  callback = callback or function(result, err)
    if err then notice(err, vim.log.levels.ERROR) end
  end
  if process then return dispatch(method, params, callback) end
  queue[#queue + 1] = { method = method, params = params, callback = callback }
  if not booting then
    booting = true
    provision()
  end
end

function M.stop()
  if process then
    stopped = process
    process:kill('sigterm')
    process = nil
  end
end

function M.update(callback)
  if booting then return callback(nil, 'Environment setup is already in progress') end
  fail('Bridge restarted for SDK update')
  M.stop()
  force_update = true
  M.call('initialize', {}, callback)
end

function M.paths()
  return { python = python, data = data, state = state }
end

return M
