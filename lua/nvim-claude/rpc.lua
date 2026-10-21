local M = { pending = {}, id = 0 }
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':h:h:h')
M.root = root
function M.stop()
  if M.job then vim.fn.chanclose(M.job, 'stdin') end
end
function M.start(opts, event)
  if M.job then return end
  M.bytes, M.errors = '', ''
  local argv = { opts.python or 'python3', root .. '/python/provision.py', '--data', opts.data_dir,
    '--state', opts.state_dir, '--config', vim.json.encode({
      model = opts.model or 'claude-haiku-5-5', effort = opts.effort or 'low',
      context_limit_tokens = opts.context_limit_tokens == false and vim.NIL or (opts.context_limit_tokens or 100000),
    }) }
  M.job = vim.fn.jobstart(argv, {
    on_stdout = function(_, chunks)
      M.bytes = M.bytes .. table.concat(chunks, '\n')
      while true do
        local finish = M.bytes:find('\r\n\r\n', 1, true)
        if not finish then return end
        local length = tonumber(M.bytes:sub(1, finish):match('[Cc]ontent%-[Ll]ength:%s*(%d+)'))
        if not length or length > 16777216 then M.stop(); return end
        if #M.bytes < finish + 3 + length then return end
        local body = M.bytes:sub(finish + 4, finish + 3 + length)
        M.bytes = M.bytes:sub(finish + 4 + length)
        local ok, message = pcall(vim.json.decode, body)
        if not ok then M.stop(); return end
        if message.id then
          local cb = M.pending[message.id]
          M.pending[message.id] = nil
          if cb then cb(message.error and message.error.message, message.result) end
        elseif message.method then event(message.method, message.params) end
      end
    end,
    on_stderr = function(_, chunks)
      local s = table.concat(chunks, '\n')
      M.errors = (M.errors .. s):sub(-12000)
      if s:find('nvim%-claude:') then vim.notify(s, vim.log.levels.INFO) end
    end,
    on_exit = function(_, code)
      M.job = nil
      local pending = M.pending; M.pending = {}
      for _, cb in pairs(pending) do cb('Bridge exited (' .. code .. '). ' .. M.errors) end
    end,
  })
  if M.job <= 0 then M.job = nil; error('Could not start Python bridge') end
end
function M.request(method, params, callback)
  assert(M.job, 'Bridge is not started')
  M.id = M.id + 1
  M.pending[M.id] = callback or function(err) if err then vim.notify(err, vim.log.levels.ERROR) end end
  local body = vim.json.encode({ jsonrpc = '2.0', id = M.id, method = method, params = params or {} })
  vim.fn.chansend(M.job, 'Content-Length: ' .. #body .. '\r\n\r\n' .. body)
  return M.id
end
function M.login(opts, update)
  local argv = { opts.python or 'python3', root .. '/python/provision.py', '--data', opts.data_dir, '--state', opts.state_dir }
  table.insert(argv, update and '--update' or '--login')
  vim.cmd('botright new')
  vim.fn.jobstart(argv, { term = true })
end
return M
