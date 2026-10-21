local config = require("nvim-claude.config")

local M = {}
local uv = vim.uv or vim.loop
local unpack = table.unpack or unpack

local MAX_HEADER_BYTES = 16384
local MAX_MESSAGE_BYTES = 64 * 1024 * 1024
local READY_MARKER = ".nvim-claude-ready.json"
local LOCK_OWNER = "owner.json"

local state = {
  phase = "idle",
  message = "Backend has not been started",
  last_error = nil,
  next_id = 1,
  input = "",
  pending = {},
  streams = {},
  start_waiters = {},
  diagnostics = {},
  handlers = {},
  stopping = false,
}

local function schedule(callback, ...)
  if not callback then
    return
  end
  local arguments = { ... }
  local count = select("#", ...)
  vim.schedule(function()
    local ok, err = xpcall(function()
      callback(unpack(arguments, 1, count))
    end, debug.traceback)
    if not ok then
      vim.notify("nvim-claude callback failed: " .. tostring(err), vim.log.levels.ERROR)
    end
  end)
end

local function encode(value)
  if vim.json and vim.json.encode then
    return vim.json.encode(value)
  end
  return vim.fn.json_encode(value)
end

local function decode(value)
  if vim.json and vim.json.decode then
    return vim.json.decode(value)
  end
  return vim.fn.json_decode(value)
end

local function copy(value, seen)
  if type(value) ~= "table" then
    return value
  end
  seen = seen or {}
  if seen[value] then
    return seen[value]
  end
  local result = {}
  seen[value] = result
  for key, child in pairs(value) do
    result[copy(key, seen)] = copy(child, seen)
  end
  return result
end

local function path_join(left, right)
  return left:gsub("[/\\]+$", "") .. "/" .. right
end

local function dirname(path)
  if vim.fs and vim.fs.dirname then
    return vim.fs.dirname(path)
  end
  return path:match("^(.*)[/\\][^/\\]+$")
end

local function plugin_root()
  local source = debug.getinfo(1, "S").source
  if source:sub(1, 1) == "@" then
    source = source:sub(2)
  end
  return dirname(dirname(dirname(source)))
end

local function venv_python(venv_dir)
  if package.config:sub(1, 1) == "\\" then
    return path_join(venv_dir, "Scripts/python.exe")
  end
  return path_join(venv_dir, "bin/python")
end

local function fs_exists(path)
  return uv.fs_stat(path) ~= nil
end

local function environment_ready(options)
  return fs_exists(venv_python(options.venv_dir))
    and fs_exists(path_join(options.venv_dir, READY_MARKER))
end

local function mkdir(path)
  local ok, err = pcall(vim.fn.mkdir, path, "p")
  if not ok or vim.fn.isdirectory(path) ~= 1 then
    return nil, tostring(err or ("could not create " .. path))
  end
  return true
end

local function write_file(path, contents, mode)
  local fd, open_err = uv.fs_open(path, "w", mode or 384)
  if not fd then
    return nil, open_err
  end
  local written, write_err = uv.fs_write(fd, contents, -1)
  uv.fs_close(fd)
  if not written then
    return nil, write_err
  end
  return true
end

local function read_file(path)
  local fd = uv.fs_open(path, "r", 384)
  if not fd then
    return nil
  end
  local stat = uv.fs_fstat(fd)
  if not stat then
    uv.fs_close(fd)
    return nil
  end
  local contents = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  return contents
end

local function remove_tree(path)
  if fs_exists(path) then
    pcall(vim.fn.delete, path, "rf")
  end
end

local function close_handle(handle)
  if handle and not handle:is_closing() then
    handle:close()
  end
end

local function callback_table(callbacks)
  if type(callbacks) == "function" then
    return { callback = callbacks }
  end
  return callbacks or {}
end

local function error_message(err)
  if type(err) == "table" then
    return tostring(err.message or err.data or err.code or "unknown backend error")
  end
  return tostring(err)
end

local function report_error(err, callbacks)
  state.last_error = err
  local cb = callback_table(callbacks)
  if cb.callback then
    schedule(cb.callback, err, nil)
  elseif cb.on_error then
    schedule(cb.on_error, err)
  elseif state.handlers.error then
    schedule(state.handlers.error, err)
  else
    schedule(vim.notify, "nvim-claude: " .. error_message(err), vim.log.levels.ERROR)
  end
end

local function report_result(result, callbacks)
  local cb = callback_table(callbacks)
  if cb.callback then
    schedule(cb.callback, nil, result)
  elseif cb.on_result then
    schedule(cb.on_result, result)
  end
end

local function emit_progress(phase, message, detail)
  state.phase = phase
  state.message = message
  local progress = { phase = phase, message = message, detail = detail }
  if state.handlers.progress then
    schedule(state.handlers.progress, copy(progress))
  end
  for _, waiter in ipairs(state.start_waiters) do
    local cb = callback_table(waiter.callbacks)
    if cb.on_progress then
      schedule(cb.on_progress, copy(progress))
    end
  end
end

local function append_diagnostic(chunk)
  if not chunk or chunk == "" then
    return
  end
  state.diagnostics[#state.diagnostics + 1] = chunk
  if #state.diagnostics > 100 then
    table.remove(state.diagnostics, 1)
  end
  if state.handlers.diagnostic then
    schedule(state.handlers.diagnostic, chunk)
  end
end

local function append_tail(current, chunk)
  current = current .. (chunk or "")
  if #current > 65536 then
    current = current:sub(-65536)
  end
  return current
end

local function run_command(program, args, phase, callback)
  local stdout = uv.new_pipe(false)
  local stderr = uv.new_pipe(false)
  local output = ""
  local errors = ""
  local handle
  local spawn_err

  handle, spawn_err = uv.spawn(program, {
    args = args,
    stdio = { nil, stdout, stderr },
  }, function(code, signal)
    vim.schedule(function()
      if state.provision_process == handle then
        state.provision_process = nil
      end
      close_handle(stdout)
      close_handle(stderr)
      close_handle(handle)
      callback(code, signal, output, errors)
    end)
  end)

  if not handle then
    close_handle(stdout)
    close_handle(stderr)
    schedule(callback, -1, 0, "", "Could not start " .. tostring(program) .. ": " .. tostring(spawn_err))
    return
  end

  state.provision_process = handle
  stdout:read_start(function(err, chunk)
    if err then
      errors = append_tail(errors, tostring(err))
    end
    if chunk then
      output = append_tail(output, chunk)
      emit_progress(phase, state.message, chunk)
    end
  end)
  stderr:read_start(function(err, chunk)
    if err then
      errors = append_tail(errors, tostring(err))
    end
    if chunk then
      errors = append_tail(errors, chunk)
      emit_progress(phase, state.message, chunk)
    end
  end)
end

local function release_lock(options)
  local lock_dir = path_join(options.data_dir, "provision.lock")
  pcall(uv.fs_unlink, path_join(lock_dir, LOCK_OWNER))
  pcall(uv.fs_rmdir, lock_dir)
end

local function provision(options, callback)
  local pid = uv.os_getpid and uv.os_getpid() or vim.fn.getpid()
  local unique = tostring(pid) .. "." .. tostring(uv.hrtime())
  local temporary = path_join(options.data_dir, "venv.tmp." .. unique)
  state.provision_temp = temporary

  local owner_ok, owner_err = write_file(path_join(options.data_dir, "provision.lock/" .. LOCK_OWNER), encode({
    pid = pid,
    temporary = temporary,
    started_at = os.time(),
  }))
  if not owner_ok then
    release_lock(options)
    callback(nil, "Could not record provisioning lock ownership: " .. tostring(owner_err))
    return
  end

  if environment_ready(options) then
    release_lock(options)
    state.provision_temp = nil
    callback(true)
    return
  end

  if fs_exists(options.venv_dir) then
    local displaced = options.venv_dir .. ".incomplete." .. unique
    local moved = uv.fs_rename(options.venv_dir, displaced)
    if moved then
      remove_tree(displaced)
    else
      remove_tree(options.venv_dir)
    end
  end
  remove_tree(temporary)

  emit_progress("provisioning", "Creating the nvim-claude Python environment")
  run_command(options.python, { "-m", "venv", temporary }, "provisioning", function(code, _, stdout, stderr)
    if code ~= 0 then
      remove_tree(temporary)
      release_lock(options)
      state.provision_temp = nil
      callback(nil, "Python virtual environment creation failed: " .. stderr .. stdout)
      return
    end

    local python = venv_python(temporary)
    emit_progress("provisioning", "Installing the latest claude-agent-sdk")
    run_command(python, {
      "-m",
      "pip",
      "install",
      "--disable-pip-version-check",
      "--no-input",
      "--upgrade",
      "claude-agent-sdk",
    }, "provisioning", function(install_code, _, install_stdout, install_stderr)
      if install_code ~= 0 then
        remove_tree(temporary)
        release_lock(options)
        state.provision_temp = nil
        callback(nil, "claude-agent-sdk installation failed: " .. install_stderr .. install_stdout)
        return
      end

      local marker_ok, marker_err = write_file(path_join(temporary, READY_MARKER), encode({
        schema = 1,
        created_at = os.time(),
        source_python = options.python,
      }))
      if not marker_ok then
        remove_tree(temporary)
        release_lock(options)
        state.provision_temp = nil
        callback(nil, "Could not mark the Python environment ready: " .. tostring(marker_err))
        return
      end

      local renamed, rename_err = uv.fs_rename(temporary, options.venv_dir)
      if not renamed and environment_ready(options) then
        remove_tree(temporary)
        renamed = true
      end
      release_lock(options)
      state.provision_temp = nil
      if not renamed then
        remove_tree(temporary)
        callback(nil, "Could not publish the Python environment: " .. tostring(rename_err))
        return
      end
      callback(true)
    end)
  end)
end

local function process_alive(pid)
  if type(pid) ~= "number" then
    return false
  end
  local ok, result = pcall(uv.kill, pid, 0)
  return ok and (result == 0 or result == true)
end

local function lock_owner(lock_dir)
  local contents = read_file(path_join(lock_dir, LOCK_OWNER))
  if not contents then
    return nil
  end
  local ok, owner = pcall(decode, contents)
  if ok and type(owner) == "table" then
    return owner
  end
  return nil
end

local function wait_for_provisioner(options, callback)
  local lock_dir = path_join(options.data_dir, "provision.lock")
  local timer = uv.new_timer()
  state.lock_timer = timer

  local function finish(ready, err)
    if state.lock_timer == timer then
      state.lock_timer = nil
    end
    timer:stop()
    close_handle(timer)
    callback(ready, err)
  end

  timer:start(100, 250, vim.schedule_wrap(function()
    if state.stopping then
      finish(nil, "Backend stopped while waiting for dependency setup")
      return
    end
    if environment_ready(options) then
      finish(true)
      return
    end
    local stat = uv.fs_stat(lock_dir)
    if not stat then
      finish(false)
      return
    end

    local owner = lock_owner(lock_dir)
    local modified = type(stat.mtime) == "table" and stat.mtime.sec or tonumber(stat.mtime)
    local age = os.time() - (modified or os.time())
    if owner and process_alive(tonumber(owner.pid)) then
      return
    end
    if not owner and age < 5 then
      return
    end

    local stale = lock_dir .. ".stale." .. tostring(uv.hrtime())
    if uv.fs_rename(lock_dir, stale) then
      remove_tree(stale)
      finish(false)
    end
  end))
end

local function acquire_environment(options, callback)
  if environment_ready(options) then
    callback(true)
    return
  end

  local created, mkdir_err = mkdir(options.data_dir)
  if not created then
    callback(nil, mkdir_err)
    return
  end
  local lock_dir = path_join(options.data_dir, "provision.lock")
  local acquired, lock_err, lock_code = uv.fs_mkdir(lock_dir, 448)
  if acquired then
    provision(options, callback)
    return
  end

  local lock_failure = tostring(lock_code or lock_err)
  if not lock_failure:find("EEXIST", 1, true) then
    callback(nil, "Could not acquire dependency setup lock: " .. lock_failure)
    return
  end

  emit_progress("waiting", "Another Neovim instance is preparing nvim-claude")
  wait_for_provisioner(options, function(ready, err)
    if err or ready then
      callback(ready, err)
    else
      acquire_environment(options, callback)
    end
  end)
end

local function stream_key(request_id, epoch)
  return tostring(request_id) .. "\0" .. tostring(epoch)
end

local function dispatch_message(message)
  if type(message) ~= "table" or message.jsonrpc ~= "2.0" then
    return nil, "Bridge sent a non-JSON-RPC message"
  end

  if message.id ~= nil then
    local pending = state.pending[tostring(message.id)]
    if not pending then
      return true
    end
    state.pending[tostring(message.id)] = nil
    if message.error ~= nil then
      if pending.stream_key then
        state.streams[pending.stream_key] = nil
      end
      report_error(message.error, pending.callbacks)
    else
      report_result(message.result, pending.callbacks)
    end
    return true
  end

  if message.method == "nvim_claude/event" and type(message.params) == "table" then
    local event = message.params
    local handlers = state.streams[stream_key(event.request_id, event.epoch)]
    if state.handlers.event then
      schedule(state.handlers.event, copy(event))
    end
    if handlers then
      if handlers.on_event then
        schedule(handlers.on_event, copy(event))
      end
      if event.type == "status" and handlers.on_progress then
        schedule(handlers.on_progress, copy(event))
      elseif event.type == "error" then
        report_error(event, handlers)
      end
      if event.type == "result" or event.type == "error" then
        state.streams[stream_key(event.request_id, event.epoch)] = nil
      end
    end
    return true
  end

  if state.handlers.notification then
    schedule(state.handlers.notification, copy(message))
  end
  return true
end

local function protocol_failure(message)
  state.phase = "error"
  state.message = message
  state.last_error = message
  if state.child and not state.child:is_closing() then
    pcall(state.child.kill, state.child, 15)
  end
end

local function consume_stdout()
  while true do
    local header_end = state.input:find("\r\n\r\n", 1, true)
    if not header_end then
      if #state.input > MAX_HEADER_BYTES then
        protocol_failure("Bridge sent an oversized or unterminated header")
      end
      return
    end

    local header = state.input:sub(1, header_end - 1)
    local content_length
    for line in (header .. "\r\n"):gmatch("(.-)\r\n") do
      local name, value = line:match("^([^:]+):%s*(.-)%s*$")
      if name and name:lower() == "content-length" then
        content_length = tonumber(value)
      end
    end
    if not content_length or content_length < 0 or content_length ~= math.floor(content_length) then
      protocol_failure("Bridge sent an invalid Content-Length header")
      return
    end
    if content_length > MAX_MESSAGE_BYTES then
      protocol_failure("Bridge sent a message larger than the transport limit")
      return
    end

    local body_start = header_end + 4
    local body_end = body_start + content_length - 1
    if #state.input < body_end then
      return
    end
    local body = state.input:sub(body_start, body_end)
    state.input = state.input:sub(body_end + 1)

    local ok, message = pcall(decode, body)
    if not ok then
      protocol_failure("Bridge sent invalid JSON: " .. tostring(message))
      return
    end
    local dispatched, dispatch_err = dispatch_message(message)
    if not dispatched then
      protocol_failure(dispatch_err)
      return
    end
  end
end

local function fail_pending(err)
  local pending = state.pending
  state.pending = {}
  for _, entry in pairs(pending) do
    if entry.stream_key then
      state.streams[entry.stream_key] = nil
    end
    report_error(err, entry.callbacks)
  end
  local streams = state.streams
  state.streams = {}
  for _, callbacks in pairs(streams) do
    report_error(err, callbacks)
  end
end

local function drain_stop_callbacks()
  local callbacks = state.stop_callbacks or {}
  state.stop_callbacks = nil
  for _, callback in ipairs(callbacks) do
    schedule(callback)
  end
end

local function bridge_exited(handle, code, signal)
  if state.child ~= handle then
    close_handle(handle)
    return
  end

  close_handle(state.stdin)
  close_handle(state.stdout)
  close_handle(state.stderr)
  close_handle(handle)
  state.stdin = nil
  state.stdout = nil
  state.stderr = nil
  state.child = nil
  state.pid = nil
  state.input = ""

  if state.stop_timer then
    state.stop_timer:stop()
    close_handle(state.stop_timer)
    state.stop_timer = nil
  end

  local stopped = state.stopping
  state.stopping = false
  if stopped then
    state.phase = "stopped"
    state.message = "Backend stopped"
    fail_pending("Backend stopped")
    drain_stop_callbacks()
  else
    local message = "Bridge exited with code " .. tostring(code) .. " and signal " .. tostring(signal)
    state.phase = "error"
    state.message = message
    state.last_error = message
    fail_pending(message)
  end
end

local function start_bridge(options, callback)
  local state_ok, state_err = mkdir(options.state_dir)
  if not state_ok then
    callback(nil, state_err)
    return
  end

  local bridge = options.bridge_path or path_join(plugin_root(), "python/nvim_claude_bridge.py")
  if not fs_exists(bridge) then
    callback(nil, "Packaged Python bridge not found at " .. bridge)
    return
  end

  local stdin = uv.new_pipe(false)
  local stdout = uv.new_pipe(false)
  local stderr = uv.new_pipe(false)
  local args = { bridge, "--state-dir", options.state_dir }
  if options.system_prompt_path then
    args[#args + 1] = "--system-prompt"
    args[#args + 1] = options.system_prompt_path
  end

  local handle, pid
  handle, pid = uv.spawn(venv_python(options.venv_dir), {
    args = args,
    stdio = { stdin, stdout, stderr },
  }, function(code, signal)
    vim.schedule(function()
      bridge_exited(handle, code, signal)
    end)
  end)

  if not handle then
    close_handle(stdin)
    close_handle(stdout)
    close_handle(stderr)
    callback(nil, "Could not start the packaged Python bridge: " .. tostring(pid))
    return
  end

  state.child = handle
  state.pid = pid
  state.stdin = stdin
  state.stdout = stdout
  state.stderr = stderr
  state.input = ""

  stdout:read_start(function(err, chunk)
    vim.schedule(function()
      if state.child ~= handle then
        return
      end
      if err then
        protocol_failure("Bridge stdout failed: " .. tostring(err))
        return
      end
      if chunk then
        state.input = state.input .. chunk
        consume_stdout()
      end
    end)
  end)
  stderr:read_start(function(err, chunk)
    vim.schedule(function()
      if state.child ~= handle then
        return
      end
      if err then
        append_diagnostic("stderr read failed: " .. tostring(err))
      end
      if chunk then
        append_diagnostic(chunk)
      end
    end)
  end)

  state.phase = "ready"
  state.message = "Backend is ready"
  state.last_error = nil
  callback(true)
end

local function drain_start_waiters(err)
  local waiters = state.start_waiters
  state.start_waiters = {}
  for _, waiter in ipairs(waiters) do
    waiter.ready(err)
  end
end

local function begin_start()
  local options = config.get()
  state.options = options
  state.stopping = false
  emit_progress("checking", "Checking the nvim-claude Python environment")
  acquire_environment(options, function(ready, provision_err)
    if not ready then
      state.phase = "error"
      state.message = provision_err
      state.last_error = provision_err
      drain_start_waiters(provision_err)
      return
    end
    if state.stopping then
      drain_start_waiters("Backend stopped before launch")
      return
    end
    emit_progress("starting", "Starting the nvim-claude bridge")
    start_bridge(options, function(started, start_err)
      if not started then
        state.phase = "error"
        state.message = start_err
        state.last_error = start_err
        drain_start_waiters(start_err)
        return
      end
      drain_start_waiters(nil)
    end)
  end)
end

local function ensure_started(callbacks, ready)
  if state.child and state.phase == "ready" then
    ready(nil)
    return
  end
  state.start_waiters[#state.start_waiters + 1] = {
    callbacks = callbacks,
    ready = ready,
  }
  if #state.start_waiters == 1 then
    begin_start()
  end
end

local function write_message(message, callback)
  if not state.stdin or not state.child then
    callback("Bridge is not running")
    return
  end
  local ok, body = pcall(encode, message)
  if not ok then
    callback("Could not encode JSON-RPC message: " .. tostring(body))
    return
  end
  local frame = "Content-Length: " .. tostring(#body) .. "\r\n\r\n" .. body
  state.stdin:write(frame, function(err)
    if err then
      schedule(callback, "Could not write to the bridge: " .. tostring(err))
    else
      schedule(callback, nil)
    end
  end)
end

local function next_id()
  local id = state.next_id
  state.next_id = id + 1
  return id
end

local function send_request(id, method, params, callbacks, request_stream_key)
  state.pending[tostring(id)] = {
    callbacks = callbacks,
    stream_key = request_stream_key,
  }
  write_message({
    jsonrpc = "2.0",
    id = id,
    method = method,
    params = params or {},
  }, function(err)
    if err and state.pending[tostring(id)] then
      state.pending[tostring(id)] = nil
      if request_stream_key then
        state.streams[request_stream_key] = nil
      end
      report_error(err, callbacks)
    end
  end)
end

function M.call(method, params, callbacks)
  assert(type(method) == "string" and method ~= "", "RPC method must be a non-empty string")
  params = params or {}
  local cb = callback_table(callbacks)
  local id = next_id()
  local key
  if method == "turn" and params.request_id ~= nil then
    key = stream_key(params.request_id, params.epoch)
    state.streams[key] = cb
  end

  ensure_started(cb, function(start_err)
    if start_err then
      if key then
        state.streams[key] = nil
      end
      report_error(start_err, cb)
      return
    end
    send_request(id, method, params, cb, key)
  end)
  return id
end

function M.initialize(params, callbacks)
  local original = callback_table(callbacks)
  local wrapped = copy(original)
  if original.callback then
    wrapped.callback = function(err, result)
      if not err then
        state.initialization = copy(result)
      end
      original.callback(err, result)
    end
  else
    wrapped.on_result = function(result)
      state.initialization = copy(result)
      if original.on_result then
        original.on_result(result)
      end
    end
  end
  return M.call("initialize", params or {}, wrapped)
end

function M.notify(method, params, callbacks)
  assert(type(method) == "string" and method ~= "", "RPC method must be a non-empty string")
  local cb = callback_table(callbacks)
  ensure_started(cb, function(start_err)
    if start_err then
      report_error(start_err, cb)
      return
    end
    write_message({
      jsonrpc = "2.0",
      method = method,
      params = params or {},
    }, function(write_err)
      if write_err then
        report_error(write_err, cb)
      elseif cb.on_result then
        schedule(cb.on_result, true)
      elseif cb.callback then
        schedule(cb.callback, nil, true)
      end
    end)
  end)
end

function M.cancel(request_id, epoch, callbacks)
  return M.call("cancel", {
    request_id = request_id,
    epoch = epoch,
  }, callbacks)
end

function M.stop(callback)
  state.stop_callbacks = state.stop_callbacks or {}
  if callback then
    state.stop_callbacks[#state.stop_callbacks + 1] = callback
  end
  if state.stopping then
    return
  end
  state.stopping = true

  if state.lock_timer then
    state.lock_timer:stop()
    close_handle(state.lock_timer)
    state.lock_timer = nil
  end
  if state.provision_process and not state.provision_process:is_closing() then
    pcall(state.provision_process.kill, state.provision_process, 15)
  end

  if not state.child then
    state.phase = "stopped"
    state.message = "Backend stopped"
    state.stopping = false
    drain_start_waiters("Backend stopped")
    drain_stop_callbacks()
    return
  end

  local shutdown_id = next_id()
  send_request(shutdown_id, "shutdown", {}, {
    on_result = function()
      if state.stdin and not state.stdin:is_closing() then
        state.stdin:shutdown(function()
          close_handle(state.stdin)
        end)
      end
    end,
    on_error = function() end,
  })

  local timer = uv.new_timer()
  state.stop_timer = timer
  timer:start(1000, 0, vim.schedule_wrap(function()
    if state.child and not state.child:is_closing() then
      pcall(state.child.kill, state.child, 15)
    end
    timer:stop()
    close_handle(timer)
    if state.stop_timer == timer then
      state.stop_timer = nil
    end
  end))
end

function M.set_handlers(handlers)
  state.handlers = handlers or {}
end

function M.status()
  local options = state.options or config.get()
  return {
    phase = state.phase,
    message = state.message,
    error = copy(state.last_error),
    ready_environment = environment_ready(options),
    running = state.child ~= nil,
    pid = state.pid,
  }
end

function M.version()
  return state.initialization and copy(state.initialization.runtime) or nil
end

function M.initialization()
  return state.initialization and copy(state.initialization) or nil
end

function M.diagnostics()
  return copy(state.diagnostics)
end

return M
