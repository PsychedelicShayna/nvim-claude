local M = {pending = {}, next_id = 0, queue = {}, starting = false}
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2))))
local function notify(text, level) vim.notify('nvim-claude: ' .. text, level) end

local function fail_all(message)
  local pending = M.pending
  M.pending = {}
  for _, callback in pairs(pending) do callback(nil, message) end
  local queue = M.queue
  M.queue = {}
  for _, request in ipairs(queue) do request[3](nil, message) end
end

local function frame(message)
  local text = vim.json.encode(message)
  if #text > 16 * 1024 * 1024 then return nil end
  return 'Content-Length: ' .. #text .. '\r\n\r\n' .. text
end

local function transmit(method, params, callback)
  M.next_id = M.next_id + 1
  local id = M.next_id
  callback = callback or function(_, err) if err then notify(err, vim.log.levels.ERROR) end end
  local encoded = frame({jsonrpc = '2.0', id = id, method = method, params = params or {}})
  if not encoded then
    callback(nil, 'Request exceeds the 16 MiB bridge frame limit; reduce the explicit buffer context')
    return id
  end
  M.pending[id] = callback
  vim.fn.chansend(M.job, encoded)
  return id
end

local function consume(chunk)
  M.input = M.input .. chunk
  while true do
    local header_end = M.input:find('\r\n\r\n', 1, true)
    if not header_end then return end
    local size = tonumber(M.input:sub(1, header_end):match('[Cc]ontent%-[Ll]ength:%s*(%d+)'))
    if not size or size > 16 * 1024 * 1024 then
      fail_all('Invalid bridge frame')
      vim.fn.jobstop(M.job)
      return
    end
    local body_start = header_end + 4
    if #M.input < body_start + size - 1 then return end
    local raw = M.input:sub(body_start, body_start + size - 1)
    M.input = M.input:sub(body_start + size)
    local ok, message = pcall(vim.json.decode, raw)
    if not ok then fail_all('Malformed bridge JSON'); return end
    if message.id then
      local callback = M.pending[message.id]
      M.pending[message.id] = nil
      if callback then callback(message.result, message.error and message.error.message) end
    elseif M.on_event then
      M.on_event(message.method, message.params)
    end
  end
end

local function launch(python)
  M.input = ''
  M.job = vim.fn.jobstart({python, root .. '/python/bridge.py'}, {
    on_stdout = function(_, data) consume(table.concat(data, '\n')) end,
    on_stderr = function(_, data)
      local text = table.concat(data, '\n')
      if text:match('%S') then M.diagnostics = text end
    end,
    on_exit = function(_, code)
      M.job = nil
      M.starting = false
      fail_all('Bridge exited (' .. code .. '). ' .. (M.diagnostics or ''))
    end,
  })
  if M.job <= 0 then M.job = nil; M.starting = false; fail_all('Cannot start Python bridge'); return end
  transmit('initialize', {state_dir = M.options.state_dir, config = M.options.config}, function(result, err)
    M.starting = false
    if err then fail_all(err); return end
    M.initial = result
    local queue = M.queue
    M.queue = {}
    for _, request in ipairs(queue) do transmit(unpack(request)) end
  end)
end

function M.ensure(update, callback)
  if M.starting then return end
  M.starting = true
  local args = {M.options.python, root .. '/python/provision.py', M.options.data_dir}
  if update then args[#args + 1] = '--update' end
  local stdout, stderr, progress = {}, '', ''
  local job = vim.fn.jobstart(args, {
    stdout_buffered = true,
    on_stdout = function(_, lines) stdout = lines end,
    on_stderr = function(_, lines)
      local chunk = table.concat(lines, '\n')
      stderr = stderr .. chunk
      progress = progress .. chunk
      while progress:find('\n', 1, true) do
        local finish = progress:find('\n', 1, true)
        local text = progress:sub(1, finish - 1)
        progress = progress:sub(finish + 1)
        if text:match('^Waiting for runtime') or text:match('^Creating private')
            or text:match('^Installing latest') then notify(text) end
      end
    end,
    on_exit = function(_, code)
      if code ~= 0 then
        M.starting = false
        local err = 'Setup failed. Check Python/venv/network, then retry.\n' .. stderr
        local queue = M.queue
        M.queue = {}
        for _, request in ipairs(queue) do request[3](nil, err) end
        notify(err, vim.log.levels.ERROR)
        return
      end
      local ok, runtime = pcall(vim.json.decode, table.concat(stdout, '\n'))
      if not ok then
        M.starting = false
        fail_all('Invalid setup result')
        notify('Invalid setup result', vim.log.levels.ERROR)
        return
      end
      M.runtime = runtime
      if callback then M.starting = false; callback(runtime) else launch(runtime.python) end
    end,
  })
  if job <= 0 then
    M.starting = false
    fail_all('Cannot start configured Python: ' .. M.options.python)
    notify('Cannot start configured Python: ' .. M.options.python, vim.log.levels.ERROR)
  end
  notify(update and 'Updating SDK runtime asynchronously' or 'Preparing SDK runtime asynchronously')
end

function M.request(method, params, callback)
  callback = callback or function(result, err)
    if err then notify(err, vim.log.levels.ERROR) elseif result then notify(vim.inspect(result)) end
  end
  if M.job and not M.starting then return transmit(method, params, callback) end
  M.queue[#M.queue + 1] = {method, params or {}, callback}
  M.ensure(false)
end

function M.setup(options, on_event)
  M.options, M.on_event = options, on_event
end

function M.stop()
  if M.job then
    -- EOF lets the bridge interrupt, disconnect and delete its own unsaved sessions.
    pcall(vim.fn.chanclose, M.job, 'stdin')
  end
end

return M
