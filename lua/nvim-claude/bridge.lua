local M = {}
local uv = vim.uv or vim.loop
local proc, pending, next_id, buffer = nil, {}, 0, ''
local booting, queue, failed = false, {}, nil
local runtime, on_event
local data_dir = vim.fn.stdpath('data') .. '/nvim-claude'
local state_dir = vim.fn.stdpath('state') .. '/nvim-claude'
local venv = data_dir .. '/venv'
local lockdir = data_dir .. '/install.lock'
local marker = data_dir .. '/sdk-ready'
local timer

local function notice(text, level)
  vim.schedule(function() vim.notify('nvim-claude: ' .. text, level or vim.log.levels.INFO) end)
end
local function flush(err)
  booting = false
  local current = queue; queue = {}
  for _, fn in ipairs(current) do fn(err) end
end
local function install_done(err)
  if timer then timer:stop(); timer:close(); timer = nil end
  uv.fs_unlink(lockdir .. '/pid')
  uv.fs_rmdir(lockdir)
  if err then failed = err; notice(err, vim.log.levels.ERROR) end
  flush(err)
end
local function command(argv, done)
  vim.system(argv, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        local detail = result.stderr and result.stderr ~= '' and result.stderr or result.stdout or 'unknown error'
        done(('%s failed (exit %s): %s'):format(argv[1], result.code, vim.trim(detail)))
      else done(nil) end
    end)
  end)
end
local function acquire(python)
  if uv.fs_stat(marker) and uv.fs_stat(venv .. '/bin/python') then flush(nil); return end
  if uv.fs_mkdir(lockdir, 448) then
    local fd = uv.fs_open(lockdir .. '/pid', 'w', 384)
    if fd then uv.fs_write(fd, tostring(uv.os_getpid()), 0); uv.fs_close(fd) end
    notice('Setting up Python and installing the latest Claude Agent SDK')
    command({ python, '-c', 'import sys; assert sys.version_info >= (3, 10), \"Python 3.10 or later is required\"' }, function(version_err)
      if version_err then return install_done(version_err) end
      command({ python, '-m', 'venv', venv }, function(err)
        if err then return install_done(err) end
        command({ venv .. '/bin/python', '-m', 'pip', 'install', '--no-input', '--disable-pip-version-check', 'claude-agent-sdk' }, function(pip_err)
          if pip_err then return install_done(pip_err) end
          local ready = uv.fs_open(marker, 'w', 384)
          if not ready then return install_done('Could not mark SDK installation ready') end
          uv.fs_write(ready, 'ready\n', 0); uv.fs_close(ready)
          install_done(nil)
        end)
      end)
    end)
    return
  end
  local fd = uv.fs_open(lockdir .. '/pid', 'r', 384)
  if fd then
    local pid = tonumber(uv.fs_read(fd, 40, 0)); uv.fs_close(fd)
    if pid and not uv.kill(pid, 0) then
      notice('Removing an abandoned SDK installation lock')
      uv.fs_unlink(lockdir .. '/pid'); uv.fs_rmdir(lockdir)
      return acquire(python)
    end
  end
  notice('Another Neovim instance is preparing the Claude SDK; waiting for it')
  local attempts = 0
  timer = uv.new_timer()
  timer:start(1000, 1000, vim.schedule_wrap(function()
    attempts = attempts + 1
    if uv.fs_stat(marker) and uv.fs_stat(venv .. '/bin/python') then
      timer:stop(); timer:close(); timer = nil; flush(nil)
    elseif not uv.fs_stat(lockdir) then
      timer:stop(); timer:close(); timer = nil; acquire(python)
    elseif attempts >= 600 then
      timer:stop(); timer:close(); timer = nil; flush('Timed out waiting for the SDK installation lock')
    end
  end))
end
local function unpack_frames()
  while true do
    local header = buffer:find('\r\n\r\n', 1, true)
    if not header then return end
    local length = tonumber(buffer:sub(1, header - 1):match('[Cc]ontent%-[Ll]ength:%s*(%d+)'))
    if not length or length > 32 * 1024 * 1024 then
      buffer = ''; M.stop('Invalid bridge frame'); return
    end
    local finish = header + 3 + length
    if #buffer < finish then return end
    local payload = buffer:sub(header + 4, finish)
    buffer = buffer:sub(finish + 1)
    local ok, message = pcall(vim.json.decode, payload)
    if ok and type(message) == 'table' then
      if message.method == 'event' then
        if on_event then on_event(message.params or {}) end
      elseif message.id ~= nil then
        local callback = pending[message.id]; pending[message.id] = nil
        if callback then callback(message.error, message.result) end
      end
    else notice('Bridge sent invalid JSON', vim.log.levels.ERROR) end
  end
end
local function start(done)
  if proc then return done(nil) end
  local script = vim.api.nvim_get_runtime_file('python/nvim_claude/bridge.py', false)[1]
  if not script then return done('Python bridge resource is missing from this plugin installation') end
  proc = vim.system({ venv .. '/bin/python', script }, {
    stdin = true, text = false,
    stdout = function(err, chunk)
      if err then return vim.schedule(function() M.stop('Bridge stdout error: ' .. tostring(err)) end) end
      if chunk then vim.schedule(function() buffer = buffer .. chunk; unpack_frames() end) end
    end,
    stderr = function(_, chunk)
      if chunk and chunk ~= '' then notice('Bridge: ' .. vim.trim(chunk), vim.log.levels.WARN) end
    end,
  }, function(result)
    vim.schedule(function()
      proc = nil; runtime = nil
      local error_message = 'Bridge exited with code ' .. tostring(result.code)
      for id, cb in pairs(pending) do pending[id] = nil; cb({ message = error_message }) end
    end)
  end)
  if not proc then return done('Could not start the Python bridge') end
  M.rpc('initialize', { state_dir = state_dir }, function(err, result)
    if err then M.stop(err.message or tostring(err)); return done(err.message or tostring(err)) end
    if result.protocol ~= 1 then M.stop('Unsupported bridge protocol'); return done('Unsupported bridge protocol') end
    runtime = result
    failed = nil
    done(nil)
  end, true)
end
function M.ensure(done)
  if runtime and proc then return done(nil) end
  queue[#queue + 1] = function(err)
    if err or (runtime and proc) then done(err)
    else M.ensure(done) end
  end
  if booting then return end
  booting = true
  uv.fs_mkdir(data_dir, 448)
  uv.fs_mkdir(state_dir, 448)
  local python = M.python or vim.fn.exepath('python3')
  if python == '' or vim.fn.executable(python) == 0 then
    return flush('Python 3.10 or later is required; configure opts.python')
  end
  local function ready(err)
    if err then return flush(err) end
    start(function(start_err)
      if start_err then failed = start_err; notice(start_err, vim.log.levels.ERROR) end
      flush(start_err)
    end)
  end
  if uv.fs_stat(marker) and uv.fs_stat(venv .. '/bin/python') then ready(nil)
  else acquire(python) end
end
function M.rpc(method, params, callback, initialized)
  if not initialized and not runtime then
    return M.ensure(function(err)
      if err then callback({ message = err }); return end
      M.rpc(method, params, callback, true)
    end)
  end
  if not proc then return callback({ message = failed or 'Bridge is not running' }) end
  next_id = next_id + 1
  local id = next_id
  pending[id] = callback
  local payload = vim.json.encode({ jsonrpc = '2.0', id = id, method = method, params = params or {} })
  local frame = ('Content-Length: %d\r\n\r\n%s'):format(#payload, payload)
  local ok, err = pcall(proc.write, proc, frame)
  if not ok then pending[id] = nil; callback({ message = tostring(err) }) end
  return id
end
function M.cancel(turn_id, epoch, done)
  M.rpc('cancel', { id = turn_id, epoch = epoch }, done or function() end)
end
function M.events(handler) on_event = handler end
function M.runtime() return runtime end
function M.stop(reason)
  if proc then proc:kill('sigterm'); proc = nil end
  runtime = nil; buffer = ''
  if reason then notice(reason, vim.log.levels.ERROR) end
end
return M
