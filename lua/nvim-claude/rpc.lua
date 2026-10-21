local M = { pending = {}, serial = 0, job = nil, ready = false, queue = {} }
local root = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/lua/nvim%-claude/rpc.lua$')
M.root = root

local function fail(message)
  local job = M.job
  M.ready, M.job = false, nil
  if job and job > 0 then
    pcall(vim.fn.chanclose, job, 'stdin')
    vim.defer_fn(function()
      if vim.fn.jobwait({ job }, 0)[1] == -1 then pcall(vim.fn.jobstop, job) end
    end, 1500)
  end
  for id, callback in pairs(M.pending) do M.pending[id] = nil; callback(nil, message) end
  for _, item in ipairs(M.queue) do item[3](nil, message) end
  M.queue = {}
end

function M.send(method, params, callback)
  M.serial = M.serial + 1
  local id = M.serial
  M.pending[id] = callback or function() end
  local body = vim.json.encode({ jsonrpc = '2.0', id = id, method = method, params = params or {} })
  local ok = pcall(vim.fn.chansend, M.job, 'Content-Length: ' .. #body .. '\r\n\r\n' .. body)
  if not ok then M.pending[id] = nil; if callback then callback(nil, 'Bridge stdin is closed') end end
  return id
end

function M.start(opts, events, callback)
  if M.ready then callback(); return end
  M.queue[#M.queue + 1] = { false, false, callback }
  if M.job then return end
  M.closing = false
  local data = opts.data_dir or (vim.fn.stdpath('data') .. '/nvim-claude')
  local state = opts.state_dir or (vim.fn.stdpath('state') .. '/nvim-claude')
  local python = opts.python or vim.fn.exepath('python3')
  if python == '' then fail('Python 3.10+ is required. Set opts.python to its executable.'); return end
  local argv = { python, root .. '/python/bootstrap.py', '--data', data, '--state', state }
  if opts.update then argv[#argv + 1] = '--update' end
  local incoming = ''
  M.job = vim.fn.jobstart(argv, {
    stdout_buffered = false,
    on_stdout = function(_, chunks)
      incoming = incoming .. table.concat(chunks, '\n')
      while true do
        local a, b = incoming:find('\r\n\r\n', 1, true)
        if not a then break end
        local length = tonumber(incoming:sub(1, a - 1):match('[Cc]ontent%-[Ll]ength:%s*(%d+)'))
        if not length or length > 32 * 1024 * 1024 then fail('Invalid bridge frame'); return end
        if #incoming - b < length then break end
        local body = incoming:sub(b + 1, b + length)
        incoming = incoming:sub(b + length + 1)
        local ok, message = pcall(vim.json.decode, body)
        if not ok then fail('Invalid bridge JSON'); return end
        if message.id then
          local cb = M.pending[message.id]
          M.pending[message.id] = nil
          if cb then cb(message.result, message.error and message.error.message) end
        elseif events then events(message.method, message.params) end
      end
    end,
    on_stderr = function(_, chunks)
      local text = table.concat(chunks, '\n')
      if text ~= '' then vim.schedule(function() vim.notify('nvim-claude: ' .. text, vim.log.levels.DEBUG) end) end
    end,
    on_exit = function(job, code)
      if not M.closing and M.job == job then fail('Bridge exited (' .. code .. '); retry or inspect :messages') end
    end,
  })
  if M.job <= 0 then fail('Could not start Python bridge'); return end
  M.send('initialize', { config = opts.model_config, billing = opts.billing or 'subscription' }, function(info, err)
    if err then fail(err); return end
    M.ready, M.info = true, info
    local queued = M.queue
    M.queue = {}
    for _, item in ipairs(queued) do item[3]() end
  end)
end

function M.call(opts, events, method, params, callback)
  M.start(opts, events, function(_, err)
    if err then callback(nil, err); return end
    if method == 'request' and params.generation <= (M.cancelled_generation or 0) then
      callback(nil, 'Cancelled before dispatch')
      return
    end
    M.send(method, params, callback)
  end)
end

function M.stop()
  if M.job then
    M.closing = true
    -- EOF lets the bridge interrupt, flush saved state, and delete owned ephemeral transcripts.
    pcall(vim.fn.chanclose, M.job, 'stdin')
    local job = M.job
    vim.fn.jobwait({ job }, 1500)
    if vim.fn.jobwait({ job }, 0)[1] == -1 then vim.fn.jobstop(job) end
  end
  M.ready, M.job = false, nil
end

return M
