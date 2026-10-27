-- Conversation state: model config, ephemeral expiry, context limit, saved records.
local bridge = require("nvim-claude.bridge")
local config = require("nvim-claude.config")

local M = {}

local state_file = vim.fn.stdpath("data") .. "/nvim-claude/state.json"
local saved_file = vim.fn.stdpath("data") .. "/nvim-claude/saved.json"

M.state = {
  model = nil,
  effort = nil,
  limit = nil,
  sticky = false,
  watermarks = "allow",
}

M.convo = nil -- { session_id, created, first_prompt, saved, last_used, context_tokens, max_tokens, seen = {bufnr=changedtick} }
M.busy = false
M.last_transition = nil
M.system_override = nil

local function read_json(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local text = f:read("*a")
  f:close()
  local ok, value = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
  return ok and value or nil
end

local function write_json(path, value)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = io.open(path, "w")
  if f then
    f:write(vim.json.encode(value))
    f:close()
  end
end

function M.load()
  local opts = config.options
  local s = read_json(state_file) or {}
  M.state.model = s.model or opts.model
  M.state.effort = s.effort or opts.effort
  M.state.limit = s.limit or opts.context_limit
  M.state.sticky = (s.sticky ~= nil) and s.sticky or opts.sticky
  M.state.watermarks = s.watermarks or opts.watermarks
end

function M.persist()
  write_json(state_file, M.state)
end

function M.system_prompt()
  if M.system_override then
    return M.system_override
  end
  local f = io.open(bridge.root() .. "/prompts/system.md", "r")
  local text = f and f:read("*a") or ""
  if f then
    f:close()
  end
  return text
end

local function saved_list()
  return read_json(saved_file) or {}
end

local function store_saved(list)
  write_json(saved_file, list)
end

local function record_saved()
  local c = M.convo
  if not (c and c.saved and c.session_id) then
    return
  end
  local list = saved_list()
  for _, item in ipairs(list) do
    if item.session_id == c.session_id or (c.record_id and item.id == c.record_id) then
      item.session_id = c.session_id
      item.updated = os.time()
      item.model = M.state.model
      store_saved(list)
      return
    end
  end
  c.record_id = c.record_id or tostring(c.created) .. "-" .. tostring(math.random(1000, 9999))
  table.insert(list, {
    id = c.record_id,
    session_id = c.session_id,
    created = c.created,
    updated = os.time(),
    first_prompt = c.first_prompt or "",
    model = M.state.model,
  })
  store_saved(list)
end

-- Push model / effort / system prompt to the bridge before a request.
function M.sync(cb)
  bridge.call("configure", {
    model = M.state.model,
    effort = M.state.effort,
    system_prompt = M.system_prompt(),
  }, function(err)
    cb(err)
  end)
end

local function fresh(reason)
  M.convo = nil
  M.last_transition = reason
end

-- Drop the working conversation and tell the bridge to start empty.
function M.new(reason, cb)
  fresh(reason or "new conversation")
  if not bridge.running() then
    return cb and cb(nil)
  end
  bridge.request("new", {}, function(err)
    if cb then
      cb(err)
    end
  end)
end

local function expired()
  local c = M.convo
  if not c or c.saved then
    return false
  end
  return c.last_used and (os.time() - c.last_used) > (config.options.expire_minutes * 60)
end

local function over_limit()
  local c = M.convo
  local limit = M.state.limit
  return c and limit and c.context_tokens and c.context_tokens >= limit
end

local function fmt_k(n)
  if not n then
    return "?"
  end
  if n >= 1000000 then
    return string.format("%.2gm", n / 1000000)
  end
  return string.format("%dk", math.floor(n / 1000 + 0.5))
end
M.fmt_k = fmt_k

function M.compact(cb)
  if M.busy then
    return cb("a request is running")
  end
  M.busy = true
  bridge.notify("compacting conversation…")
  bridge.call("compact", {}, function(err, res)
    M.busy = false
    if err or not (res and res.ok) then
      return cb(err or (res and res.reason) or "compaction failed")
    end
    if M.convo then
      M.convo.session_id = res.session_id or M.convo.session_id
      M.convo.context_tokens = res.context_tokens or res.post_tokens
      M.convo.seen = {} -- a summary is not an exact document baseline
    end
    M.last_transition = string.format("compacted %s → %s", fmt_k(res.pre_tokens), fmt_k(M.convo and M.convo.context_tokens))
    record_saved()
    bridge.notify(M.last_transition)
    cb(nil)
  end)
end

-- Decide what to do at the limit; cb(err) once the conversation is ready.
local function handle_limit(cb)
  local used = M.convo.context_tokens
  local choice = config.options.on_limit
  local function act(which)
    if which == "compact" then
      M.compact(function(err)
        if err then
          bridge.notify("compaction failed (" .. err .. "); starting a new conversation", vim.log.levels.WARN)
          return M.new("new conversation after failed compaction", cb)
        end
        cb(nil)
      end)
    elseif which == "new" then
      M.new(string.format("new conversation at limit (%s / %s)", fmt_k(used), fmt_k(M.state.limit)), cb)
    else
      cb("cancelled")
    end
  end
  if choice == "new" or choice == "compact" then
    return act(choice)
  end
  local msg = string.format("nvim-claude: context limit reached (%s / %s).", fmt_k(used), fmt_k(M.state.limit))
  local pick = vim.fn.confirm(msg, "&New conversation\n&Compact\n&Keep going", 1)
  if pick == 1 then
    act("new")
  elseif pick == 2 then
    act("compact")
  elseif pick == 3 then
    M.convo.context_tokens = nil -- ask again after the next turn
    cb(nil)
  else
    cb("cancelled")
  end
end

-- Called before every request. cb(err) when it is safe to send.
function M.prepare(cb)
  if expired() then
    return M.new("previous conversation expired", function()
      M.sync(cb)
    end)
  end
  if over_limit() then
    return handle_limit(function(err)
      if err then
        return cb(err)
      end
      M.sync(cb)
    end)
  end
  M.sync(cb)
end

function M.begin(first_prompt)
  if not M.convo then
    M.convo = {
      created = os.time(),
      first_prompt = first_prompt,
      saved = M.state.sticky,
      seen = {},
    }
  end
  return M.convo
end

function M.finish(res)
  local c = M.convo
  if not c then
    return
  end
  c.last_used = os.time()
  c.session_id = res.session_id or c.session_id
  c.context_tokens = res.context_tokens or c.context_tokens
  c.max_tokens = res.max_tokens or c.max_tokens
  record_saved()
end

function M.save()
  if not (M.convo and M.convo.session_id) then
    bridge.notify("nothing to save yet; send a request first", vim.log.levels.WARN)
    return
  end
  M.convo.saved = true
  record_saved()
  bridge.notify("conversation saved")
end

function M.set_sticky(on)
  if on == nil then
    on = not M.state.sticky
  end
  M.state.sticky = on
  M.persist()
  if on and M.convo and M.convo.session_id then
    M.convo.saved = true
    record_saved()
  end
  bridge.notify("sticky " .. (on and "on" or "off"))
end

function M.saved()
  local list = saved_list()
  table.sort(list, function(a, b)
    return (a.updated or a.created or 0) > (b.updated or b.created or 0)
  end)
  return list
end

function M.resume(item, cb)
  M.convo = {
    created = item.created,
    first_prompt = item.first_prompt,
    saved = true,
    seen = {},
    session_id = item.session_id,
    record_id = item.id,
    last_used = os.time(),
  }
  M.last_transition = "resumed saved conversation"
  bridge.call("resume", { session_id = item.session_id }, function(err)
    if cb then
      cb(err)
    end
  end)
end

return M
