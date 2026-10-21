local M = {}
local root = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/lua/nvim%-claude/backend%.lua$')
local opts, job, seq, pending, waiting = {}, nil, 0, {}, {}
local incoming, starting, initialized = '', false, false
local function notify(message, level) vim.schedule(function() vim.notify('nvim-claude: ' .. message, level) end) end
local function finish(err)
  local callbacks = waiting
  waiting, starting = {}, false
  for _, cb in ipairs(callbacks) do cb(err) end
end
local function send(method, params, cb)
  seq = seq + 1
  pending[seq] = cb or function() end
  local body = vim.json.encode({ jsonrpc = '2.0', id = seq, method = method, params = params or {} })
  vim.fn.chansend(job, 'Content-Length: ' .. #body .. '\r\n\r\n' .. body)
end
local function consume(data)
  incoming = incoming .. data
  while true do
    local stop = incoming:find('\r\n\r\n', 1, true)
    if not stop then return end
    local header = incoming:sub(1, stop - 1)
    local length = tonumber(header:lower():match('content%-length:%s*(%d+)'))
    if not length or length > 67108864 then
      notify('Invalid bridge frame', vim.log.levels.ERROR)
      if job then vim.fn.jobstop(job) end
      return
    end
    local first = stop + 4
    if #incoming < first + length - 1 then return end
    local body = incoming:sub(first, first + length - 1)
    incoming = incoming:sub(first + length)
    local ok, message = pcall(vim.json.decode, body)
    if not ok then notify('Invalid JSON from bridge', vim.log.levels.ERROR)
    elseif message.id then
      local cb = pending[message.id]
      pending[message.id] = nil
      if cb then cb(message.error and (message.error.message or vim.inspect(message.error)), message.result) end
    elseif message.method and M.on_event then M.on_event(message.method, message.params or {}) end
  end
end
local function launch(python)
  job = vim.fn.jobstart({ python, root .. '/python/bridge.py', '--state', vim.fn.stdpath('state') .. '/nvim-claude' }, {
    on_stdout = function(_, data) consume(table.concat(data, '\n')) end,
    on_stderr = function(_, data)
      local s = table.concat(data, '\n')
      if s:match('%S') then M.diagnostics = (M.diagnostics or '') .. s end
    end,
    on_exit = function(id, code)
      if job ~= id then return end
      job, initialized = nil, false
      local callbacks = pending; pending = {}
      for _, cb in pairs(callbacks) do cb('Bridge exited (' .. code .. '). ' .. (M.diagnostics or '')) end
      if starting then finish('Bridge exited before initialization') end
    end,
  })
  if job <= 0 then job = nil; finish('Unable to start Python bridge'); return end
  send('initialize', { config = { model = opts.model or 'claude-haiku-5-5', effort = opts.effort or 'low', context_limit_tokens = opts.context_limit_tokens or 100000 } }, function(err, result)
    if not err then initialized = true; M.initialization = result end
    finish(err)
  end)
end
local function provision(update, cb)
  local runtime = opts.runtime_dir or vim.fn.stdpath('data') .. '/nvim-claude/runtime'
  local python = opts.python or vim.fn.exepath('python3')
  if python == '' then python = vim.fn.exepath('python') end
  if python == '' then cb('Python 3.10+ was not found; set opts.python'); return end
  vim.fn.mkdir(vim.fn.fnamemodify(runtime, ':h'), 'p')
  -- flock owns installation across processes; Python code is fixed, never user input.
  local script = [[import os,sys,subprocess,venv
root,update=sys.argv[1],sys.argv[2]=='1'
exe=os.path.join(root,'bin','python')
ready=os.path.join(root,'.nvim-claude-ready')
if not os.path.isfile(ready) or update:
 os.makedirs(root,exist_ok=True)
 if os.path.exists(ready): os.unlink(ready)
 if not os.path.isfile(exe): venv.EnvBuilder(with_pip=True).create(root)
 subprocess.run([exe,'-m','pip','install','--upgrade','claude-agent-sdk'],check=True)
 subprocess.run([exe,'-c','import claude_agent_sdk'],check=True)
 with open(ready,'w') as f: f.write('ready\n')
]]
  if vim.fn.executable('flock') ~= 1 then cb('flock is required for safe cross-instance runtime installation'); return end
  notify(update and 'Updating Claude Agent SDK…' or 'Preparing Python runtime…')
  vim.system({ 'flock', runtime .. '.lock', python, '-c', script, runtime, update and '1' or '0' }, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then cb('Runtime installation failed: ' .. (result.stderr or '') .. (result.stdout or ''))
      else cb(nil, runtime .. '/bin/python') end
    end)
  end)
end
function M.setup(value) opts = value end
function M.ensure(cb)
  if initialized and job then cb(); return end
  table.insert(waiting, cb)
  if starting then return end
  starting = true
  provision(false, function(err, python)
    if err then finish(err) else launch(python) end
  end)
end
function M.request(method, params, cb, current)
  M.ensure(function(err)
    if err then (cb or function(e) notify(e, vim.log.levels.ERROR) end)(err); return end
    if current and not current() then return end
    send(method, params, cb)
  end)
end
function M.update(cb)
  if starting then cb('Runtime is being prepared'); return end
  if job then vim.fn.chanclose(job, 'stdin'); job = nil; initialized = false end
  provision(true, function(err) cb(err) end)
end
function M.stop() if job then pcall(vim.fn.chanclose, job, 'stdin') end end
M.root = root
return M
