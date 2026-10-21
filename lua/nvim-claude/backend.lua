local uv = vim.uv
local M = { seq = 0, callbacks = {}, pending = {}, buffer = '', ready = false }
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2))))
local data = vim.fn.stdpath('data') .. '/nvim-claude'
local state = vim.fn.stdpath('state') .. '/nvim-claude'
local python = data .. '/venv/bin/python'
local bridge = root .. '/python/nvim_claude_bridge.py'
local on_event = nil
local jobs = {}
local ready_marker = data .. '/installed'

local function notify(message, level)
  vim.schedule(function() vim.notify('nvim-claude: ' .. message, level or vim.log.levels.INFO) end)
end

local function run(executable, args, callback)
  local stdout, stderr = uv.new_pipe(false), uv.new_pipe(false)
  local chunks = {}
  local proc
  proc = uv.spawn(executable, { args = args, stdio = { nil, stdout, stderr }, cwd = data }, function(code, signal)
    vim.schedule(function()
      jobs[proc] = nil
      stdout:read_stop(); stderr:read_stop()
      stdout:close(); stderr:close(); proc:close()
      callback(code == 0 and signal == 0, table.concat(chunks))
    end)
  end)
  if not proc then
    stdout:close(); stderr:close()
    callback(false, 'Cannot start ' .. executable)
    return
  end
  jobs[proc] = true
  stderr:read_start(function(_, chunk) if chunk then chunks[#chunks + 1] = chunk end end)
  stdout:read_start(function(_, chunk) if chunk then chunks[#chunks + 1] = chunk end end)
end

local function start()
  if M.process or M.starting then return end
  M.starting = true
  local input, output, errors = uv.new_pipe(false), uv.new_pipe(false), uv.new_pipe(false)
  local proc
  local env = {}
  for key, value in pairs(vim.fn.environ()) do env[#env + 1] = key .. '=' .. value end
  env[#env + 1] = 'NVCLAUDE_STATE=' .. state
  proc = uv.spawn(python, { args = { '-u', bridge }, cwd = state,
    env = env, stdio = { input, output, errors } }, function(code)
    vim.schedule(function()
      local was_ready = M.ready
      M.process = nil; M.ready = false; M.starting = false
      input:close(); output:close(); errors:close(); proc:close()
      local pending = M.callbacks
      M.callbacks = {}
      if not M.stopping then
        for _, cb in pairs(pending) do cb(nil, 'Bridge exited (' .. code .. ')') end
        if was_ready then notify('Python bridge exited (' .. code .. ')', vim.log.levels.ERROR) end
      end
    end)
  end)
  if not proc then
    input:close(); output:close(); errors:close()
    M.starting = false
    notify('Could not launch Python bridge', vim.log.levels.ERROR)
    return
  end
  M.stopping = false
  M.process, M.input = proc, input
  errors:read_start(function(_, chunk) if chunk then notify(chunk, vim.log.levels.ERROR) end end)
  output:read_start(function(err, chunk)
    if err then notify(err, vim.log.levels.ERROR); return end
    if not chunk then return end
    M.buffer = M.buffer .. chunk
    while true do
      local split = M.buffer:find('\r\n\r\n', 1, true)
      if not split then break end
      local header = M.buffer:sub(1, split - 1)
      local length = tonumber(header:match('[Cc]ontent%-[Ll]ength:%s*(%d+)'))
      if not length or length > 32 * 1024 * 1024 then notify('Invalid bridge frame', vim.log.levels.ERROR); break end
      local last = split + 3 + length
      if #M.buffer < last then break end
      local ok, message = pcall(vim.json.decode, M.buffer:sub(split + 4, last))
      M.buffer = M.buffer:sub(last + 1)
      if ok then vim.schedule(function()
        if message.id then
          local cb = M.callbacks[message.id]
          M.callbacks[message.id] = nil
          if cb then cb(message.result, message.error and message.error.message, message.id) end
        elseif on_event then on_event(message.method, message.params) end
      end) else notify('Invalid bridge JSON', vim.log.levels.ERROR) end
    end
  end)
  M.ready = true
  M.starting = false
  local pending = M.pending
  M.pending = {}
  for _, item in ipairs(pending) do item.dispatch() end
end

local function provision()
  if M.provisioning then return end
  M.provisioning = true
  vim.fn.mkdir(data, 'p'); vim.fn.mkdir(state, 'p')
  local function finish(ok, err)
    M.provisioning = false
    if ok then start() else
      notify('Setup failed: ' .. (err or 'unknown error'), vim.log.levels.ERROR)
      local pending = M.pending; M.pending = {}
      for _, item in ipairs(pending) do item.dispatch(false, err) end
    end
  end
  if vim.fn.executable(python) == 1 and uv.fs_stat(ready_marker) then finish(true); return end
  local lock = data .. '/install.lock'
  local fd = uv.fs_open(lock, 'wx', 384)
  if not fd then
    local attempts = 0
    local timer = uv.new_timer()
    timer:start(1000, 1000, vim.schedule_wrap(function()
      attempts = attempts + 1
      if uv.fs_stat(ready_marker) and not uv.fs_stat(lock) then
        timer:stop(); timer:close(); finish(true)
      elseif attempts > 2 then
        local ok, owner = pcall(vim.fn.readfile, lock)
        local pid = ok and tonumber(owner[1])
        if pid and not uv.kill(pid, 0) then
          timer:stop(); timer:close(); uv.fs_unlink(lock)
          M.provisioning = false
          provision()
        elseif attempts >= 180 then
          timer:stop(); timer:close(); finish(false, 'another installer did not finish')
        end
      end
    end))
    notify('Waiting for another Neovim instance to finish SDK setup')
    return
  end
  uv.fs_write(fd, tostring(uv.os_getpid()), -1)
  uv.fs_close(fd)
  M.install_lock = lock
  local function install()
    notify('Installing the latest claude-agent-sdk in the plugin environment')
    run(python, { '-m', 'pip', 'install', '--no-cache-dir', '--disable-pip-version-check', 'claude-agent-sdk' }, function(installed, output)
      if installed then
        local marker = uv.fs_open(ready_marker, 'w', 384)
        if marker then uv.fs_close(marker) end
      end
      M.install_lock = nil
      uv.fs_unlink(lock)
      finish(installed, output)
    end)
  end
  if vim.fn.executable(python) == 1 then install(); return end
  notify('Creating Python environment (first use)')
  local system = M.system_python or vim.fn.exepath('python3')
  if system == '' then M.install_lock = nil; uv.fs_unlink(lock); finish(false, 'Python 3.10+ is required'); return end
  run(system, { '-m', 'venv', data .. '/venv' }, function(ok, err)
    if not ok then M.install_lock = nil; uv.fs_unlink(lock); finish(false, err); return end
    install()
  end)
end

function M.configure(opts, events)
  M.system_python = opts.python
  on_event = events
end

function M.call(method, params, callback)
  local function dispatch(ok, err)
    if ok == false then if callback then callback(nil, err) end; return end
    M.seq = M.seq + 1
    local id = M.seq
    if callback then M.callbacks[id] = callback end
    local body = vim.json.encode({ jsonrpc = '2.0', id = id, method = method, params = params or {} })
    M.input:write('Content-Length: ' .. #body .. '\r\n\r\n' .. body)
    return id
  end
  if M.ready then return dispatch() end
  M.pending[#M.pending + 1] = { method = method, dispatch = dispatch }
  provision()
end

function M.discard_pending_request()
  for index = #M.pending, 1, -1 do
    if M.pending[index].method == 'request' then table.remove(M.pending, index) end
  end
end

function M.stop()
  M.stopping = true
  if M.process then M.process:kill('sigterm') end
  for job in pairs(jobs) do job:kill('sigterm') end
  if M.install_lock then uv.fs_unlink(M.install_lock); M.install_lock = nil end
end

return M
