local M = {}
local api = vim.api

local process = nil
local next_id = 0
local pending = {}
local receive_buffer = ""
local starting = false
local ready = false
local queued = {}
local handlers = {}
local runtime_info = nil
local opts = nil

local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
local script = root .. "/python/nvim_claude_bridge.py"
local system_prompt = root .. "/resources/system-prompt.txt"
local runtime_dir = vim.fn.stdpath("data") .. "/nvim-claude/runtime"
local state_dir = vim.fn.stdpath("state") .. "/nvim-claude"

local function notify_error(message)
  vim.notify("NvClaude: " .. message, vim.log.levels.ERROR)
end

local function reject_all(message)
  for id, callback in pairs(pending) do
    pending[id] = nil
    callback(nil, message)
  end
end

local function dispatch(message)
  if message.id ~= nil then
    local callback = pending[message.id]
    pending[message.id] = nil
    if callback then
      if message.error then callback(nil, message.error.message or "bridge error")
      else callback(message.result, nil) end
    end
    return
  end
  local handler = handlers[message.method]
  if handler then handler(message.params or {}) end
end

local function parse_frames(chunk)
  receive_buffer = receive_buffer .. (chunk or "")
  while true do
    local header_end = receive_buffer:find("\r\n\r\n", 1, true)
    if not header_end then return end
    local headers = receive_buffer:sub(1, header_end - 1)
    local length = tonumber(headers:match("[Cc]ontent%-[Ll]ength:%s*(%d+)"))
    if not length then
      receive_buffer = ""
      notify_error("bridge sent an invalid frame")
      return
    end
    local body_start = header_end + 4
    if #receive_buffer < body_start + length - 1 then return end
    local body = receive_buffer:sub(body_start, body_start + length - 1)
    receive_buffer = receive_buffer:sub(body_start + length)
    local ok, message = pcall(vim.json.decode, body)
    if ok then vim.schedule(function() dispatch(message) end)
    else notify_error("bridge sent invalid JSON") end
  end
end

local function raw_call(method, params, callback)
  if not process then callback(nil, "bridge is not running"); return end
  next_id = next_id + 1
  local id = next_id
  pending[id] = callback
  local body = vim.json.encode({ jsonrpc = "2.0", id = id, method = method, params = params or {} })
  local frame = ("Content-Length: %d\r\n\r\n%s"):format(#body, body)
  process:write(frame)
end

local function flush_queue()
  local values = queued
  queued = {}
  for _, item in ipairs(values) do raw_call(item.method, item.params, item.callback) end
end

local function fail_queue(message)
  local values = queued
  queued = {}
  for _, item in ipairs(values) do item.callback(nil, message) end
end

local function start_bridge()
  local python = runtime_dir .. "/venv/bin/python"
  receive_buffer = ""
  local spawned
  spawned = vim.system({
    python, script, "--serve", "--state-dir", state_dir, "--system-prompt", system_prompt,
  }, {
    stdin = true,
    stdout = function(_, data) if data then parse_frames(data) end end,
    stderr = function(_, data)
      if data and vim.trim(data) ~= "" then
        vim.schedule(function() vim.notify("NvClaude bridge: " .. vim.trim(data), vim.log.levels.WARN) end)
      end
    end,
  }, function(result)
    vim.schedule(function()
      if process ~= spawned then return end
      process = nil
      ready = false
      starting = false
      reject_all("bridge exited with code " .. result.code)
    end)
  end)
  process = spawned
  raw_call("initialize", {}, function(result, err)
    starting = false
    if err then
      ready = false
      fail_queue(err)
      notify_error(err)
      return
    end
    ready = true
    runtime_info = result
    flush_queue()
  end)
end

local function provision(update)
  if starting then return end
  starting = true
  local python = opts.python or vim.fn.exepath("python3") or vim.fn.exepath("python")
  if python == "" then
    starting = false
    fail_queue("Python 3.10 or newer was not found")
    return
  end
  local command = { python, script, "--provision", runtime_dir }
  if update then table.insert(command, "--update") end
  vim.notify("NvClaude: preparing the Claude Agent SDK asynchronously", vim.log.levels.INFO)
  vim.system(command, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        starting = false
        local message = vim.trim(result.stderr or result.stdout or "SDK installation failed")
        fail_queue(message)
        notify_error(message)
        return
      end
      start_bridge()
    end)
  end)
end

function M.setup(options)
  opts = options
  api.nvim_create_autocmd("VimLeavePre", {
    group = api.nvim_create_augroup("nvim-claude-bridge", { clear = true }),
    callback = function() M.stop() end,
  })
end

function M.on(method, handler)
  handlers[method] = handler
end

function M.call(method, params, callback)
  callback = callback or function() end
  if ready then raw_call(method, params, callback); return end
  table.insert(queued, { method = method, params = params or {}, callback = callback })
  if not starting then provision(false) end
end

function M.update(callback)
  M.stop()
  table.insert(queued, { method = "initialize", params = {}, callback = callback or function() end })
  provision(true)
end

function M.stop()
  if not process then return end
  local current = process
  raw_call("shutdown", {}, function() end)
  vim.defer_fn(function()
    if process == current then current:kill(15) end
  end, 500)
  process = nil
  ready = false
end

function M.info()
  return runtime_info
end

function M.root()
  return root
end

return M
