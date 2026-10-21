local M = { pending = {}, next_id = 0, ready = false, waiting = {}, epoch = 0 }
local api = vim.api
local source = debug.getinfo(1, 'S').source:sub(2)
M.root = vim.fn.fnamemodify(source, ':h:h:h')
local input, stderr = '', {}

local function notify(text, level)
  vim.notify(text, level or vim.log.levels.INFO, { title = 'nvim-claude' })
end
local function fail(message)
  M.ready = false
  local pending, waiting = M.pending, M.waiting
  M.pending, M.waiting = {}, {}
  for _, cb in pairs(pending) do cb(nil, message) end
  for _, item in ipairs(waiting) do item.cb(nil, message) end
end
local function write(method, params, cb)
  M.next_id = M.next_id + 1
  local id = M.next_id
  M.pending[id] = cb
  if not params or next(params) == nil then params = vim.empty_dict() end
  local body = vim.json.encode({ jsonrpc = '2.0', id = id, method = method, params = params })
  local ok = pcall(api.nvim_chan_send, M.job, 'Content-Length: ' .. #body .. '\r\n\r\n' .. body)
  if not ok then M.pending[id] = nil; cb(nil, 'Bridge pipe closed') end
  return id
end
local function receive(chunk)
  input = input .. chunk
  while true do
    local start, finish = input:find('\r\n\r\n', 1, true)
    if not start then return end
    local length = tonumber(input:sub(1, start - 1):lower():match('content%-length:%s*(%d+)'))
    if not length or length > 32 * 1024 * 1024 then
      fail('Invalid bridge frame'); vim.fn.jobstop(M.job); return
    end
    if #input - finish < length then return end
    local body = input:sub(finish + 1, finish + length)
    input = input:sub(finish + length + 1)
    local ok, frame = pcall(vim.json.decode, body)
    if not ok then fail('Invalid bridge JSON'); vim.fn.jobstop(M.job); return end
    if frame.method == 'event' then
      if M.on_event then M.on_event(frame.params) end
    elseif frame.id and M.pending[frame.id] then
      local callback = M.pending[frame.id]
      M.pending[frame.id] = nil
      callback(frame.result, frame.error and frame.error.message)
    end
  end
end

function M.configure(opts)
  M.opts = opts
end

function M.start(update)
  if M.job then return end
  input, stderr = '', {}
  local opts = M.opts
  local argv = { opts.python or 'python3', M.root .. '/python/bootstrap.py',
    '--data', opts.data_dir or (vim.fn.stdpath('data') .. '/nvim-claude'),
    '--state', opts.state_dir or (vim.fn.stdpath('state') .. '/nvim-claude') }
  if update then argv[#argv + 1] = '--update' end
  M.job = vim.fn.jobstart(argv, {
    on_stdout = function(_, data)
      local chunk = table.concat(data, '\n')
      vim.schedule(function() receive(chunk) end)
    end,
    on_stderr = function(_, data)
      vim.schedule(function()
        for _, line in ipairs(data) do
          if line ~= '' then
            stderr[#stderr + 1] = line
            if #stderr > 12 then table.remove(stderr, 1) end
            if line:match('^nvim%-claude:') then notify(line) end
          end
        end
      end)
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        M.job = nil
        if M.stopping then M.stopping = false; return end
        fail('Bridge exited (' .. code .. '): ' .. table.concat(stderr, '\n'))
      end)
    end,
  })
  if M.job <= 0 then M.job = nil; fail('Cannot launch Python; configure opts.python'); return end
  write('initialize', { config = { model = opts.model or 'claude-haiku-5-5',
    effort = opts.effort == false and vim.NIL or (opts.effort or 'low'),
    context_limit_tokens = opts.context_limit_tokens == false and vim.NIL or (opts.context_limit_tokens or 100000),
    billing = opts.billing or 'subscription' } }, function(result, err)
    if err then fail(err); return end
    M.versions = result
    M.ready = true
    local queue = M.waiting
    M.waiting = {}
    local function next_item(i)
      local item = queue[i]
      if not item then return end
      write(item.method, item.params, function(value, failure)
        item.cb(value, failure)
        next_item(i + 1)
      end)
    end
    next_item(1)
  end)
end

function M.request(method, params, callback)
  callback = callback or function(result, err)
    if err then notify(err, vim.log.levels.ERROR)
    elseif result then notify(vim.inspect(result)) end
  end
  if not M.ready then
    M.waiting[#M.waiting + 1] = { method = method, params = params or {}, cb = callback }
    M.start()
    return
  end
  return write(method, params, callback)
end

function M.cancel(callback)
  M.epoch = M.epoch + 1
  if M.job then
    write('cancel', {}, function(_, err) if callback then callback(err) end end)
  elseif callback then callback() end
end

function M.stop()
  if not M.job then return end
  M.stopping = true
  local job = M.job
  M.ready = false
  write('shutdown', {}, function() end)
  -- The bridge drains interruption and closes its SDK client before exiting.
  vim.defer_fn(function() if M.job == job then vim.fn.jobstop(job) end end, 3000)
end

return M
