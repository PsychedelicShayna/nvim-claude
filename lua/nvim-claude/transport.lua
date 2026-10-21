local M = {}
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':h:h:h')
local state = vim.fn.stdpath('state') .. '/nvim-claude'
local data = vim.fn.stdpath('data') .. '/nvim-claude'
local python = data .. '/venv/bin/python'
local pending, seq, job, stream, installing = {}, 0, nil, '', false
local ready = data .. '/venv/.nvim-claude-ready'
local on_event

local function notify(text, level)
  vim.schedule(function() vim.notify('nvim-claude: ' .. text, level or vim.log.levels.INFO) end)
end

local function frame(obj)
  local json = vim.json.encode(obj)
  return 'Content-Length: ' .. #json .. '\r\n\r\n' .. json
end

local function parse()
  while true do
    local pos = stream:find('\r\n\r\n', 1, true)
    if not pos then return end
    local head = stream:sub(1, pos - 1)
    local size = tonumber(head:match('[Cc]ontent%-[Ll]ength:%s*(%d+)'))
    if not size or size > 16 * 1024 * 1024 then
      notify('Malformed bridge frame', vim.log.levels.ERROR)
      stream = ''
      return
    end
    if #stream < pos + 3 + size then return end
    local ok, msg = pcall(vim.json.decode, stream:sub(pos + 4, pos + 3 + size))
    stream = stream:sub(pos + 4 + size)
    if ok and type(msg) == 'table' then
      vim.schedule(function()
        if msg.id and pending[msg.id] then
          local cb = pending[msg.id]
          pending[msg.id] = nil
          cb(msg.error, msg.result, msg)
        elseif msg.method and on_event then
          on_event(msg.method, msg.params or {})
        end
      end)
    end
  end
end

local function start(callback)
  if job then return callback() end
  vim.fn.mkdir(state, 'p')
  job = vim.fn.jobstart({ python, root .. '/python/nvim_claude_bridge.py', state }, {
    rpc = false,
    on_stdout = function(_, chunks)
      stream = stream .. table.concat(chunks, '\n')
      parse()
    end,
    on_stderr = function(_, chunks)
      local text = table.concat(chunks, '\n')
      if text ~= '' then notify(text, vim.log.levels.WARN) end
    end,
    on_exit = function(_, code)
      job = nil
      for id, cb in pairs(pending) do
        pending[id] = nil
        cb('Bridge exited (' .. code .. ')')
      end
    end,
  })
  if job <= 0 then
    job = nil
    callback('Could not start Python bridge')
  else
    callback()
  end
end

local function provision(callback)
  if vim.fn.filereadable(ready) == 1 and vim.fn.executable(python) == 1 then return start(callback) end
  if installing then return callback('SDK provisioning in progress; retry when setup finishes') end
  local interpreter = M.interpreter or vim.fn.exepath('python3')
  if interpreter == '' then return callback('Python 3.10+ not found') end
  installing = true
  vim.fn.mkdir(data, 'p')
  notify('Installing the SDK asynchronously (other Neovim instances wait on a file lock)')
  local setup = vim.fn.jobstart({ interpreter, root .. '/python/bootstrap.py', data }, {
    on_stderr = function(_, chunks)
      local text = table.concat(chunks, '\n')
      if text ~= '' then notify(text, vim.log.levels.ERROR) end
    end,
    on_exit = function(_, code)
      installing = false
      if code ~= 0 then return callback('SDK setup failed (exit ' .. code .. '); check Python, pip and network') end
      start(callback)
    end,
  })
  if setup <= 0 then
    installing = false
    callback('Cannot launch Python environment setup')
  end
end

function M.request(method, params, callback)
  provision(function(err)
    if err then return callback(err) end
    seq = seq + 1
    pending[seq] = callback
    vim.fn.chansend(job, frame({ id = seq, method = method, params = params }))
  end)
end

function M.login()
  provision(function(err)
    if err then return notify(err, vim.log.levels.ERROR) end
    vim.cmd('botright new')
    local script = 'import os,pathlib,claude_agent_sdk; p=pathlib.Path(claude_agent_sdk.__file__).parent/\"_bundled\"/\"claude\"; os.execv(str(p),[str(p),\"auth\",\"login\"])'
    vim.fn.termopen({ python, '-c', script })
    vim.cmd.startinsert()
  end)
end

function M.events(callback)
  on_event = callback
end

function M.stop()
  if job then vim.fn.jobstop(job); job = nil end
end

return M
