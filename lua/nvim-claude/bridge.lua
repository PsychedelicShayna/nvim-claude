local M = {}
local uv = vim.uv or vim.loop
local config = require("nvim-claude.config")

local state = { status = "idle", next_id = 0, pending = {}, notifications = {}, queued = {}, buffer = "", process = nil }

local function plugin_root()
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
end

local function paths()
  local root = vim.fs.joinpath(vim.fn.stdpath("data"), "nvim-claude")
  return root, vim.fs.joinpath(root, "venv"), vim.fs.joinpath(root, "install.lock")
end

local function notify(message, level)
  vim.schedule(function() vim.notify("nvim-claude: " .. message, level or vim.log.levels.INFO) end)
end

local function run(argv, callback)
  local stdout, stderr = uv.new_pipe(false), uv.new_pipe(false)
  local out, err = {}, {}
  local handle
  handle = uv.spawn(argv[1], { args = vim.list_slice(argv, 2), stdio = { nil, stdout, stderr } }, function(code)
    stdout:read_stop(); stderr:read_stop(); stdout:close(); stderr:close(); handle:close()
    vim.schedule(function() callback(code, table.concat(out), table.concat(err)) end)
  end)
  if not handle then callback(127, "", "could not start " .. argv[1]); return end
  stdout:read_start(function(_, chunk) if chunk then out[#out + 1] = chunk end end)
  stderr:read_start(function(_, chunk) if chunk then err[#err + 1] = chunk end end)
end

local function python_path(venv)
  return vim.fs.joinpath(venv, vim.fn.has("win32") == 1 and "Scripts/python.exe" or "bin/python")
end

local function provision(done)
  local root, venv, lock = paths()
  vim.fn.mkdir(root, "p")
  local python = python_path(venv)
  if uv.fs_stat(python) then done(nil, python); return end
  local acquired = uv.fs_mkdir(lock, 448)
  if not acquired then
    notify("another Neovim instance is provisioning the SDK; waiting")
    local timer = uv.new_timer()
    timer:start(500, 500, function()
      if uv.fs_stat(python) then
        timer:stop(); timer:close()
        vim.schedule(function() done(nil, python) end)
      elseif not uv.fs_stat(lock) then
        timer:stop(); timer:close()
        vim.schedule(function() provision(done) end)
      end
    end)
    return
  end
  state.status = "provisioning"
  notify("creating the Python environment")
  local source_python = config.current.python or vim.fn.exepath("python3")
  if source_python == "" then uv.fs_rmdir(lock); done("Python 3.10 or newer was not found"); return end
  run({ source_python, "-m", "venv", venv }, function(code, _, err)
    if code ~= 0 then uv.fs_rmdir(lock); done("venv creation failed: " .. err); return end
    notify("installing the latest claude-agent-sdk")
    run({ python, "-m", "pip", "install", "--disable-pip-version-check", "claude-agent-sdk" }, function(pip_code, _, pip_err)
      uv.fs_rmdir(lock)
      if pip_code ~= 0 then done("SDK installation failed: " .. pip_err); return end
      done(nil, python)
    end)
  end)
end

local function dispatch(message)
  if message.id then
    local callback = state.pending[message.id]
    state.pending[message.id] = nil
    if callback then callback(message.error, message.result) end
  elseif message.method then
    local handlers = state.notifications[message.method] or {}
    for _, handler in ipairs(handlers) do handler(message.params or {}) end
  end
end

local function consume(chunk)
  state.buffer = state.buffer .. chunk
  while true do
    local header_end = state.buffer:find("\r\n\r\n", 1, true)
    if not header_end then return end
    local header = state.buffer:sub(1, header_end - 1)
    local length = tonumber(header:match("[Cc]ontent%-[Ll]ength:%s*(%d+)"))
    if not length then state.buffer = ""; notify("bridge sent an invalid frame", vim.log.levels.ERROR); return end
    local body_start = header_end + 4
    if #state.buffer < body_start + length - 1 then return end
    local body = state.buffer:sub(body_start, body_start + length - 1)
    state.buffer = state.buffer:sub(body_start + length)
    local ok, message = pcall(vim.json.decode, body)
    if ok then vim.schedule(function() dispatch(message) end) else notify("bridge sent invalid JSON", vim.log.levels.ERROR) end
  end
end

local function send(method, params, callback)
  state.next_id = state.next_id + 1
  local id = state.next_id
  state.pending[id] = callback or function() end
  local body = vim.json.encode({ jsonrpc = "2.0", id = id, method = method, params = params or {} })
  state.stdin:write("Content-Length: " .. #body .. "\r\n\r\n" .. body)
  return id
end

local function start(done)
  if state.status == "ready" then done(); return end
  state.queued[#state.queued + 1] = done
  if state.status == "starting" or state.status == "provisioning" then return end
  state.status = "starting"
  provision(function(err, python)
    if err then state.status = "failed"; notify(err, vim.log.levels.ERROR); return end
    local stdin, stdout, stderr = uv.new_pipe(false), uv.new_pipe(false), uv.new_pipe(false)
    local script = vim.fs.joinpath(plugin_root(), "python", "nvim_claude_bridge.py")
    local process
    process = uv.spawn(python, { args = { script }, stdio = { stdin, stdout, stderr } }, function(code)
      state.status = "failed"; state.process = nil
      stdin:close(); stdout:close(); stderr:close(); process:close()
      if code ~= 0 then notify("bridge exited with status " .. code, vim.log.levels.ERROR) end
    end)
    if not process then state.status = "failed"; notify("could not start the Python bridge", vim.log.levels.ERROR); return end
    state.process, state.stdin = process, stdin
    stdout:read_start(function(err_read, chunk)
      if err_read then notify("bridge read failed: " .. err_read, vim.log.levels.ERROR) elseif chunk then consume(chunk) end
    end)
    stderr:read_start(function(_, chunk) if chunk and vim.trim(chunk) ~= "" then notify(vim.trim(chunk), vim.log.levels.WARN) end end)
    send("initialize", {
      plugin_root = plugin_root(),
      state_dir = vim.fs.joinpath(vim.fn.stdpath("state"), "nvim-claude"),
      model = config.current.model,
      effort = config.current.effort,
      context_limit_tokens = config.current.context_limit_tokens,
      cache_ttl_seconds = config.current.cache_ttl_seconds,
    }, function(init_err)
      if init_err then state.status = "failed"; notify(init_err.message or tostring(init_err), vim.log.levels.ERROR); return end
      state.status = "ready"
      local queued = state.queued; state.queued = {}
      for _, callback in ipairs(queued) do callback() end
    end)
  end)
end

function M.request(method, params, callback)
  start(function() send(method, params, callback) end)
end

function M.on(method, callback)
  state.notifications[method] = state.notifications[method] or {}
  table.insert(state.notifications[method], callback)
end

function M.status() return state.status end

function M.stop()
  if state.status == "ready" then send("shutdown", {}, function() end) end
end

return M
