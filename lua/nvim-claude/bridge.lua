-- Python environment provisioning and the stdio bridge process.
local config = require("nvim-claude.config")

local M = {}

local uv = vim.uv or vim.loop
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")
local data_dir = vim.fn.stdpath("data") .. "/nvim-claude"
local venv = data_dir .. "/venv"
local venv_python = venv .. "/bin/python"
local ready_marker = venv .. "/.nvim-claude-ready"
local lock_dir = data_dir .. "/install.lock"

local job = nil -- vim.system handle for the bridge
local partial = ""
local next_id = 0
local pending = {} -- id -> { on_result = fn, on_event = fn }
local waiting = {} -- callbacks waiting for the bridge to start
local starting = false
M.info = nil -- init result: python / sdk / cli versions

local function notify(msg, level)
  vim.schedule(function()
    vim.notify("nvim-claude: " .. msg, level or vim.log.levels.INFO)
  end)
end
M.notify = notify

function M.root()
  return root
end

local function find_python()
  local configured = config.options.python
  if configured and configured ~= "" then
    return vim.fn.exepath(configured) ~= "" and vim.fn.exepath(configured) or configured
  end
  for _, name in ipairs({ "python3", "python" }) do
    local path = vim.fn.exepath(name)
    if path ~= "" then
      return path
    end
  end
end

local function run(cmd, on_done)
  vim.system(cmd, { text = true }, function(res)
    vim.schedule(function()
      on_done(res.code == 0, (res.stderr or "") .. (res.stdout or ""))
    end)
  end)
end

local function tail(text)
  local lines = vim.split(vim.trim(text or ""), "\n")
  return table.concat(vim.list_slice(lines, math.max(1, #lines - 6)), "\n")
end

-- Create the venv and install the SDK. Runs once; a lock directory keeps
-- concurrent Neovim instances from installing into the same half-built venv.
local function provision(upgrade, on_done)
  if not upgrade and uv.fs_stat(ready_marker) then
    return on_done(true)
  end
  vim.fn.mkdir(data_dir, "p")
  if not uv.fs_mkdir(lock_dir, 448) then
    local stat = uv.fs_stat(lock_dir)
    if stat and os.time() - stat.mtime.sec > 600 then
      uv.fs_rmdir(lock_dir)
      return provision(upgrade, on_done)
    end
    notify("another Neovim is installing the Python environment; waiting…")
    return vim.defer_fn(function()
      provision(upgrade, on_done)
    end, 3000)
  end
  local function finish(ok, err)
    uv.fs_rmdir(lock_dir)
    on_done(ok, err)
  end
  local function install()
    notify((upgrade and "upgrading" or "installing") .. " claude-agent-sdk…")
    run({ venv_python, "-m", "pip", "install", "--quiet", "--upgrade", "pip", "claude-agent-sdk" }, function(ok, out)
      if not ok then
        return finish(false, "pip install claude-agent-sdk failed:\n" .. tail(out))
      end
      local f = io.open(ready_marker, "w")
      if f then
        f:write(os.date("!%Y-%m-%dT%H:%M:%SZ"))
        f:close()
      end
      notify("Python environment ready")
      finish(true)
    end)
  end
  if uv.fs_stat(venv_python) then
    return install()
  end
  local python = find_python()
  if not python then
    return finish(false, "no python3 found; set opts.python")
  end
  notify("creating Python environment at " .. venv .. "…")
  run({ python, "-m", "venv", venv }, function(ok, out)
    if not ok then
      return finish(false, "python -m venv failed:\n" .. tail(out))
    end
    install()
  end)
end

local function dispatch(line)
  local ok, msg = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
  if not ok or type(msg) ~= "table" then
    return
  end
  local entry = msg.id and pending[msg.id]
  if not entry then
    return
  end
  if msg.event then
    if entry.on_event then
      entry.on_event(msg)
    end
    return
  end
  pending[msg.id] = nil
  entry.on_result(msg.error, msg.result)
end

local function on_stdout(_, data)
  if not data then
    return
  end
  partial = partial .. data
  while true do
    local nl = partial:find("\n", 1, true)
    if not nl then
      break
    end
    local line = partial:sub(1, nl - 1)
    partial = partial:sub(nl + 1)
    if line ~= "" then
      vim.schedule(function()
        dispatch(line)
      end)
    end
  end
end

local log_path = vim.fn.stdpath("state") .. "/nvim-claude.log"
function M.log_path()
  return log_path
end

local function on_stderr(_, data)
  if not data then
    return
  end
  local f = io.open(log_path, "a")
  if f then
    f:write(data)
    f:close()
  end
end

local function flush_waiting(err)
  local cbs = waiting
  waiting = {}
  starting = false
  for _, cb in ipairs(cbs) do
    cb(err)
  end
end

local function spawn()
  local workspace = vim.fn.stdpath("state") .. "/nvim-claude/workspace"
  vim.fn.mkdir(workspace, "p")
  partial = ""
  local ok, handle = pcall(vim.system, { venv_python, root .. "/python/nvim_claude_bridge.py", workspace }, {
    stdin = true,
    stdout = on_stdout,
    stderr = on_stderr,
    cwd = workspace,
  }, function(res)
    vim.schedule(function()
      job = nil
      M.info = nil
      for id, entry in pairs(pending) do
        pending[id] = nil
        entry.on_result("bridge exited (code " .. tostring(res.code) .. "); see " .. log_path)
      end
    end)
  end)
  if not ok then
    return flush_waiting("could not start bridge: " .. tostring(handle))
  end
  job = handle
  M.request("init", {}, function(err, result)
    if err then
      return flush_waiting("bridge init failed: " .. err)
    end
    M.info = result
    flush_waiting(nil)
  end)
end

-- Ensure the bridge is running; cb(err).
function M.ensure(cb)
  if job and M.info then
    return cb(nil)
  end
  table.insert(waiting, cb)
  if starting then
    return
  end
  starting = true
  provision(false, function(ok, err)
    if not ok then
      return flush_waiting(err)
    end
    spawn()
  end)
end

function M.request(method, params, on_result, on_event)
  if not job then
    return on_result("bridge not running")
  end
  next_id = next_id + 1
  local id = next_id
  pending[id] = { on_result = on_result, on_event = on_event }
  job:write(vim.json.encode({ id = id, method = method, params = params or vim.empty_dict() }) .. "\n")
  return id
end

-- Start the bridge if needed, then send a request.
function M.call(method, params, on_result, on_event)
  M.ensure(function(err)
    if err then
      return on_result(err)
    end
    M.request(method, params, on_result, on_event)
  end)
end

function M.running()
  return job ~= nil
end

function M.upgrade(cb)
  M.stop()
  provision(true, function(ok, err)
    if cb then
      cb(ok and nil or err)
    elseif not ok then
      notify(err, vim.log.levels.ERROR)
    end
  end)
end

function M.stop()
  if job then
    pcall(function()
      job:write(vim.json.encode({ id = 0, method = "shutdown" }) .. "\n")
      job:write(nil)
    end)
    local j = job
    job = nil
    M.info = nil
    vim.defer_fn(function()
      pcall(function()
        j:kill(15)
      end)
    end, 1500)
  end
end

function M.cli_path()
  return M.info and M.info.cli_path
end

return M
