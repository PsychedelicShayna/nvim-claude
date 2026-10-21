local util = require("nvim-claude.util")

local M = {}
local state = {
  config = nil,
  process = nil,
  stdin = nil,
  stdout = nil,
  stderr = nil,
  read_buffer = "",
  stderr_buffer = "",
  next_id = 1,
  pending = {},
  provision_waiting = {},
  start_waiting = {},
  provisioning = false,
  starting = false,
  notification = nil,
  instance_id = util.uuid(),
}

local function paths()
  local data = vim.fn.stdpath("data") .. "/nvim-claude"
  local runtime = data .. "/runtime"
  return {
    data = data,
    runtime = runtime,
    python = runtime .. "/bin/python",
    marker = runtime .. "/.ready.json",
    lock = data .. "/provision.lock",
    state = vim.fn.stdpath("state") .. "/nvim-claude",
  }
end

local function flush_provision_waiters(ok, value)
  local waiting = state.provision_waiting
  state.provision_waiting = {}
  for _, callback in ipairs(waiting) do
    callback(ok, value)
  end
end

local function run(argv, callback)
  local stdout, stderr = vim.uv.new_pipe(false), vim.uv.new_pipe(false)
  local output, errors = {}, {}
  local handle
  handle = vim.uv.spawn(argv[1], {
    args = vim.list_slice(argv, 2),
    stdio = { nil, stdout, stderr },
    hide = true,
  }, function(code, signal)
    stdout:read_stop()
    stderr:read_stop()
    stdout:close()
    stderr:close()
    handle:close()
    vim.schedule(function()
      callback(code == 0, table.concat(errors), table.concat(output), code, signal)
    end)
  end)
  if not handle then
    stdout:close()
    stderr:close()
    callback(false, "Could not start " .. argv[1])
    return
  end
  stdout:read_start(function(err, chunk)
    if err then table.insert(errors, err) end
    if chunk then table.insert(output, chunk) end
  end)
  stderr:read_start(function(err, chunk)
    if err then table.insert(errors, err) end
    if chunk then
      table.insert(errors, chunk)
      if #table.concat(errors) > 65536 then
        errors = { table.concat(errors):sub(-65536) }
      end
    end
  end)
end

local function release_lock(lock)
  pcall(vim.fn.delete, lock, "rf")
end

local function finish_provision(ok, message)
  state.provisioning = false
  flush_provision_waiters(ok, message)
end

local function acquire_lock(p, on_acquired)
  vim.fn.mkdir(p.data, "p")
  local ok = vim.uv.fs_mkdir(p.lock, 448)
  if ok then
    util.write_file(p.lock .. "/owner.json", vim.json.encode({ pid = vim.fn.getpid(), started = os.time() }))
    on_acquired()
    return
  end

  local timer = vim.uv.new_timer()
  local attempts = 0
  timer:start(250, 500, vim.schedule_wrap(function()
    attempts = attempts + 1
    if vim.uv.fs_stat(p.marker) and vim.uv.fs_stat(p.python) then
      timer:stop(); timer:close()
      finish_provision(true, p.python)
      return
    end
    local owner = util.json_read(p.lock .. "/owner.json", {})
    if attempts > 240 or (owner.pid and not util.is_process_alive(owner.pid)) then
      timer:stop(); timer:close()
      release_lock(p.lock)
      acquire_lock(p, on_acquired)
    end
  end))
end

local function provision()
  if state.provisioning then
    return
  end
  state.provisioning = true
  local p = paths()
  if vim.uv.fs_stat(p.marker) and vim.uv.fs_stat(p.python) then
    finish_provision(true, p.python)
    return
  end

  acquire_lock(p, function()
    if vim.uv.fs_stat(p.marker) and vim.uv.fs_stat(p.python) then
      release_lock(p.lock)
      finish_provision(true, p.python)
      return
    end
    local system_python = state.config.python or vim.fn.exepath("python3")
    if system_python == "" then
      system_python = vim.fn.exepath("python")
    end
    if system_python == "" then
      release_lock(p.lock)
      finish_provision(false, "Python 3.10 or newer was not found")
      return
    end
    local staging = p.runtime .. ".building-" .. vim.fn.getpid()
    pcall(vim.fn.delete, staging, "rf")
    util.notify("creating the Python environment")
    run({ system_python, "-m", "venv", staging }, function(created, create_error)
      if not created then
        release_lock(p.lock)
        finish_provision(false, "venv creation failed: " .. vim.trim(create_error))
        return
      end
      util.notify("installing the latest Claude Agent SDK")
      run({ staging .. "/bin/python", "-m", "pip", "install", "--disable-pip-version-check", "--upgrade", "claude-agent-sdk" }, function(installed, install_error)
        if not installed then
          pcall(vim.fn.delete, staging, "rf")
          release_lock(p.lock)
          finish_provision(false, "SDK installation failed: " .. vim.trim(install_error))
          return
        end
        pcall(vim.fn.delete, p.runtime, "rf")
        local renamed, rename_error = vim.uv.fs_rename(staging, p.runtime)
        if not renamed then
          pcall(vim.fn.delete, staging, "rf")
          release_lock(p.lock)
          finish_provision(false, "Could not publish the runtime: " .. tostring(rename_error))
          return
        end
        util.write_file(p.marker, vim.json.encode({ installed_at = os.time(), source_python = system_python }))
        release_lock(p.lock)
        finish_provision(true, p.python)
      end)
    end)
  end)
end

local function send(message)
  if not state.stdin then
    return false
  end
  local payload = vim.json.encode(message)
  state.stdin:write(("Content-Length: %d\r\n\r\n%s"):format(#payload, payload))
  return true
end

local function fail_pending(message)
  for id, callback in pairs(state.pending) do
    state.pending[id] = nil
    callback(nil, { code = -32000, message = message })
  end
end

local function dispatch(message)
  if message.id ~= nil then
    local callback = state.pending[message.id]
    if callback then
      state.pending[message.id] = nil
      callback(message.result, message.error)
    end
  elseif message.method and state.notification then
    state.notification(message.method, message.params or {})
  end
end

local function parse_frames()
  while true do
    local header_end = state.read_buffer:find("\r\n\r\n", 1, true)
    if not header_end then return end
    local header = state.read_buffer:sub(1, header_end - 1)
    local length = tonumber(header:match("[Cc]ontent%-[Ll]ength:%s*(%d+)"))
    if not length then
      state.read_buffer = ""
      util.notify("bridge sent an invalid frame", vim.log.levels.ERROR)
      return
    end
    local body_start = header_end + 4
    if #state.read_buffer < body_start + length - 1 then return end
    local body = state.read_buffer:sub(body_start, body_start + length - 1)
    state.read_buffer = state.read_buffer:sub(body_start + length)
    local ok, message = pcall(vim.json.decode, body)
    if ok then
      vim.schedule(function() dispatch(message) end)
    else
      util.notify("bridge sent invalid JSON", vim.log.levels.ERROR)
    end
  end
end

local function finish_start(ok, value)
  state.starting = false
  local waiting = state.start_waiting
  state.start_waiting = {}
  for _, callback in ipairs(waiting) do
    callback(ok, value)
  end
end

local function start(callback)
  if state.process then
    callback(true)
    return
  end
  table.insert(state.start_waiting, callback)
  if state.starting then
    return
  end
  state.starting = true
  table.insert(state.provision_waiting, function(ok, python)
    if not ok then
      finish_start(false, python)
      return
    end
    local p = paths()
    vim.fn.mkdir(p.state, "p")
    state.stdin, state.stdout, state.stderr = vim.uv.new_pipe(false), vim.uv.new_pipe(false), vim.uv.new_pipe(false)
    local script = util.plugin_root() .. "/python/nvim_claude_bridge.py"
    local handle
    handle = vim.uv.spawn(python, {
      args = { "-u", script, "--state-dir", p.state, "--resource", util.plugin_root() .. "/resources/system_prompt.txt", "--instance-id", state.instance_id },
      stdio = { state.stdin, state.stdout, state.stderr },
      hide = true,
    }, function(code, signal)
      if state.stdout then state.stdout:read_stop(); state.stdout:close() end
      if state.stderr then state.stderr:read_stop(); state.stderr:close() end
      if state.stdin then state.stdin:close() end
      if handle then handle:close() end
      state.process, state.stdin, state.stdout, state.stderr = nil, nil, nil, nil
      vim.schedule(function()
        fail_pending(("bridge exited with code %d (signal %d)%s"):format(code, signal, state.stderr_buffer ~= "" and (": " .. vim.trim(state.stderr_buffer)) or ""))
      end)
    end)
    if not handle then
      state.process, state.stdin, state.stdout, state.stderr = nil, nil, nil, nil
      finish_start(false, "could not start the Python bridge")
      return
    end
    state.process = handle
    state.stdout:read_start(function(err, chunk)
      if err then util.notify(err, vim.log.levels.ERROR) end
      if chunk then state.read_buffer = state.read_buffer .. chunk; parse_frames() end
    end)
    state.stderr:read_start(function(_, chunk)
      if chunk then state.stderr_buffer = (state.stderr_buffer .. chunk):sub(-65536) end
    end)
    send({ jsonrpc = "2.0", id = 0, method = "initialize", params = { pid = vim.fn.getpid() } })
    finish_start(true)
  end)
  provision()
end

function M.setup(config, notification)
  state.config = config
  state.notification = notification
end

function M.call(method, params, callback)
  start(function(ok, err)
    if not ok then
      callback(nil, { message = err })
      return
    end
    local id = state.next_id
    state.next_id = id + 1
    state.pending[id] = callback
    send({ jsonrpc = "2.0", id = id, method = method, params = params or {} })
  end)
end

function M.notify(method, params)
  start(function(ok)
    if ok then
      send({ jsonrpc = "2.0", method = method, params = params or {} })
    end
  end)
end

function M.update(callback)
  callback = callback or function() end
  if state.provisioning or state.starting then
    callback(false, "runtime provisioning is already in progress")
    return
  end
  local function rebuild()
    local p = paths()
    if vim.uv.fs_stat(p.runtime) and vim.fn.delete(p.runtime, "rf") ~= 0 then
      callback(false, "could not remove the existing plugin runtime")
      return
    end
    state.stderr_buffer = ""
    start(callback)
  end
  if not state.process then
    rebuild()
    return
  end
  send({ jsonrpc = "2.0", method = "shutdown", params = {} })
  local timer = vim.uv.new_timer()
  local attempts = 0
  timer:start(50, 50, vim.schedule_wrap(function()
    attempts = attempts + 1
    if not state.process then
      timer:stop()
      timer:close()
      rebuild()
    elseif attempts >= 200 then
      timer:stop()
      timer:close()
      callback(false, "the existing bridge did not stop")
    end
  end))
end

function M.stop()
  if state.process then
    send({ jsonrpc = "2.0", method = "shutdown", params = {} })
    local handle = state.process
    vim.defer_fn(function()
      if state.process == handle and not handle:is_closing() then
        handle:kill("sigterm")
      end
    end, 500)
  end
end

function M.paths()
  return paths()
end

return M
