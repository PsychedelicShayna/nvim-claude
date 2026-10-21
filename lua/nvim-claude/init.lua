local M = {}
local config = require("nvim-claude.config")
local bridge = require("nvim-claude.bridge")
local target = require("nvim-claude.target")
local context = require("nvim-claude.context")
local ui = require("nvim-claude.ui")
local normalize = require("nvim-claude.normalize")

local initialized = false
local active
local installed_mappings = {}
local next_request = 0
local punctuation = "allow"
local system_override

local function notify(message, level)
  vim.notify("nvim-claude: " .. message, level or vim.log.levels.INFO)
end

local function is_visual()
  local mode = vim.fn.mode(1)
  return mode:find("v", 1, true) ~= nil or mode == "V" or mode:byte() == 22
end

local function envelope(raw, request_target)
  local ok, value = pcall(vim.json.decode, raw)
  if not ok or type(value) ~= "table" then return nil, "Claude returned an invalid edit envelope." end
  if value.status == "needs_input" and type(value.message) == "string" and value.replacements == nil then return nil, value.message, true end
  if value.status ~= "ok" or type(value.replacements) ~= "table" then return nil, "Claude returned an unknown edit status." end
  local expected, seen = {}, {}
  for _, segment in ipairs(request_target.segments) do expected[segment.id] = segment.block end
  if #value.replacements ~= #request_target.segments then return nil, "Claude returned the wrong number of replacements." end
  for _, replacement in ipairs(value.replacements) do
    if type(replacement) ~= "table" or type(replacement.id) ~= "string" or type(replacement.text) ~= "string" then return nil, "Claude returned a malformed replacement." end
    if not expected[replacement.id] and expected[replacement.id] ~= false then return nil, "Claude returned an unknown target ID." end
    if seen[replacement.id] then return nil, "Claude returned a duplicate target ID." end
    if expected[replacement.id] and replacement.text:find("\n", 1, true) then return nil, "Claude returned a multiline block replacement." end
    seen[replacement.id] = true
    replacement.text = normalize.apply(replacement.text, punctuation)
  end
  for id in pairs(expected) do if not seen[id] then return nil, "Claude omitted target " .. id .. "." end end
  return value.replacements
end

local function submit(operation, request_target, instruction)
  if active then notify("a request is already running; the draft was not sent", vim.log.levels.WARN); return end
  next_request = next_request + 1
  local request_id = tostring(next_request)
  local payload = { operation = operation, instruction = instruction }
  local candidate
  if request_target then
    local supplied
    supplied, candidate = context.build(request_target, config.current.context_limit_tokens)
    payload.document, payload.context = supplied.document, supplied.context
    payload._snapshot_after_compaction = supplied.fallback
    payload.targets = target.payload(request_target)
  end
  active = { id = request_id, operation = operation, target = request_target, origin = request_target and request_target.win or vim.api.nvim_get_current_win(), candidate = candidate, streamed = "" }
  notify(operation .. " request started")
  bridge.request("request", { request_id = request_id, payload = payload }, function(err)
    if err then active = nil; notify(err.message or tostring(err), vim.log.levels.ERROR) end
  end)
end

local function invoke(operation, options)
  options = options or {}
  local visual = options.visual == true or (options.visual == nil and is_visual())
  local request_target
  if operation == "ask" then
    if options.previous then
      request_target = target.previous_ask(vim.api.nvim_get_current_buf())
      if not request_target then notify("no valid selected-ask target exists", vim.log.levels.WARN); return end
    elseif visual then
      request_target = target.capture("ask", true)
    elseif options.mapping then
      request_target = target.previous_ask(vim.api.nvim_get_current_buf())
    end
  else
    local err
    request_target, err = target.capture(operation, visual)
    if not request_target then notify(err, vim.log.levels.WARN); return end
    target.break_ask_chain()
  end
  local title = operation:gsub("^%l", string.upper) .. " · " .. config.current.model
  local origin = request_target and request_target.win or vim.api.nvim_get_current_win()
  ui.prompt(title, origin, function(instruction) submit(operation, request_target, instruction) end)
end

local function command(action, params, callback)
  params = params or {}
  params.action = action
  bridge.request("command", params, function(err, result)
    if err then notify(err.message or tostring(err), vim.log.levels.ERROR); return end
    if action == "new" or action == "clear" or action == "compact" or action == "resume" then context.reset() end
    notify(action .. " complete")
    if callback then callback(result) end
  end)
end

local limits = { 50000, 90000, 100000, 124000, 150000, 164000, 200000, 224000, 256000, 258000, 274000, 278000, 300000, 374000, 378000, 384000, 412000, 456000, 500000, 512000, 600000, 650000, 700000, 750000, 800000, 850000, 900000, 950000, 980000 }

local function set_model(parsed)
  config.current.model, config.current.effort, config.current.context_limit_tokens = parsed.model, parsed.effort, parsed.context_limit_tokens
  command("set_config", parsed)
end

local function manual_model()
  local default = config.current.model .. "[limit=" .. config.current.context_limit_tokens .. "]:" .. (config.current.effort or "low")
  ui.input("Model expression: ", default, function(value)
    if not value then return end
    local ok, parsed = pcall(config.parse_model, value, config.current)
    if not ok then notify(parsed, vim.log.levels.ERROR); return end
    set_model(parsed)
  end)
end

local function model_picker()
  bridge.request("models", {}, function(err, result)
    if err then notify(err.message or tostring(err), vim.log.levels.ERROR); return end
    local models = result.models or {}
    if #models == 0 then notify("runtime model discovery is unavailable; use :NvClaude model manual", vim.log.levels.WARN); manual_model(); return end
    ui.select("Model", models, function(item) return type(item) == "table" and (item.displayName or item.name or item.id) or tostring(item) end, function(choice)
      if not choice then return end
      local slug = type(choice) == "table" and (choice.id or choice.value or choice.name) or choice
      local efforts = type(choice) == "table" and (choice.efforts or choice.supportedEfforts or choice.supportedEffortLevels) or nil
      local function choose_limit(effort)
        local choices = vim.list_extend({ "model default" }, vim.deepcopy(limits))
        ui.select("Context limit", choices, tostring, function(limit)
          if not limit then return end
          set_model({ model = slug, effort = effort, context_limit_tokens = limit == "model default" and config.current.context_limit_tokens or limit })
        end)
      end
      if efforts and #efforts > 0 then ui.select("Effort", efforts, tostring, function(effort) if effort then choose_limit(effort) end end) else choose_limit(nil) end
    end)
  end)
end

local function show_info()
  bridge.request("info", {}, function(err, result)
    if err then notify(err.message or tostring(err), vim.log.levels.ERROR); return end
    ui.finish("info", vim.inspect(result), "nvim-claude info", vim.api.nvim_get_current_win())
  end)
end

local function list_conversations()
  bridge.request("list", {}, function(err, result)
    if err then notify(err.message or tostring(err), vim.log.levels.ERROR); return end
    ui.select("Saved conversations", result, function(item)
      return os.date("!%y:%m:%d:%H:%M:%S", item.created) .. " - " .. item.first_prompt:sub(1, 60) .. " [" .. item.id:sub(-8) .. "]"
    end, function(choice) if choice then command("resume", { id = choice.id }) end end)
  end)
end

local function modify_system()
  local resource = vim.fs.joinpath(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))), "resources", "system-prompt.txt")
  local text = system_override or table.concat(vim.fn.readfile(resource), "\n") .. "\n"
  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_name(buf, "nvim-claude://system-prompt")
  vim.bo[buf].buftype = "acwrite"; vim.bo[buf].filetype = "text"; vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n", { plain = true }))
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_create_autocmd("BufWriteCmd", { buffer = buf, callback = function()
    system_override = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    command("system_prompt", { text = system_override }, function() vim.bo[buf].modified = false end)
  end })
end

local function login()
  bridge.request("login", {}, function(err, result)
    if err or not result.argv then notify(err and err.message or "bundled Claude login is unavailable", vim.log.levels.ERROR); return end
    vim.cmd("botright new")
    vim.fn.jobstart(result.argv, { term = true })
    vim.cmd.startinsert()
  end)
end

local actions = {
  replace = function() invoke("replace") end,
  ask = function() invoke("ask", { mapping = true }) end,
  generate = function() invoke("generate", { visual = false }) end,
  model = model_picker,
  model_manual = manual_model,
  clear = function() command("clear") end,
  new = function() command("new") end,
  sticky = function() command("sticky") end,
  save = function() command("save") end,
  info = show_info,
  list = list_conversations,
}

local commands = { "ask", "replace", "generate", "cancel", "clear", "new", "save", "sticky", "compact", "list", "info", "model", "watermarks", "system", "login" }

local function dispatch(args)
  local words = vim.split(args.args, "%s+", { trimempty = true })
  local name = words[1] or "ask"
  if name == "ask" then invoke("ask", { visual = false, previous = words[2] == "previous" })
  elseif name == "replace" then invoke("replace")
  elseif name == "generate" then invoke("generate", { visual = false })
  elseif name == "cancel" then bridge.request("cancel", { request_id = active and active.id }, function() active = nil; notify("request cancelled") end)
  elseif name == "clear" or name == "new" or name == "save" or name == "compact" then command(name)
  elseif name == "sticky" then command("sticky", { value = words[2] == "on" and true or words[2] == "off" and false or nil })
  elseif name == "list" then list_conversations()
  elseif name == "info" then show_info()
  elseif name == "model" and words[2] == "manual" then manual_model()
  elseif name == "model" then model_picker()
  elseif name == "watermarks" then
    local policy = words[2]
    if policy ~= "allow" and policy ~= "remove" and policy ~= "replace" then notify("use watermarks allow, remove, or replace", vim.log.levels.ERROR); return end
    punctuation = policy; notify("punctuation policy: " .. policy)
  elseif name == "system" and words[2] == "modify" then modify_system()
  elseif name == "system" and words[2] == "default" then
    system_override = nil
    local resource = vim.fs.joinpath(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))), "resources", "system-prompt.txt")
    command("system_prompt", { text = table.concat(vim.fn.readfile(resource), "\n") .. "\n" })
  elseif name == "login" then login()
  else notify("unknown command: " .. name, vim.log.levels.ERROR) end
end

local function complete(arglead, cmdline)
  local words = vim.split(cmdline, "%s+", { trimempty = true })
  local values = commands
  if words[2] == "watermarks" then values = { "allow", "remove", "replace" }
  elseif words[2] == "sticky" then values = { "on", "off" }
  elseif words[2] == "system" then values = { "modify", "default" }
  elseif words[2] == "model" then values = { "manual" }
  elseif words[2] == "ask" then values = { "previous" } end
  return vim.tbl_filter(function(value) return value:find("^" .. vim.pesc(arglead)) ~= nil end, values)
end

local function install_mapping(mode, lhs, callback, description, explicit)
  if not lhs or lhs == false then return end
  local modes = type(mode) == "table" and mode or { mode }
  for _, item in ipairs(modes) do
    if explicit or vim.fn.maparg(lhs, item) == "" then
      vim.keymap.set(item, lhs, callback, { desc = description, silent = true })
      installed_mappings[#installed_mappings + 1] = { mode = item, lhs = lhs }
    end
  end
end

function M.setup(opts)
  opts = opts or {}
  local explicit = type(opts.keys) == "table" and opts.keys or {}
  config.setup(opts)
  punctuation = config.current.punctuation
  if not initialized then
    vim.api.nvim_create_user_command("NvClaude", dispatch, { nargs = "*", range = true, complete = complete })
    bridge.on("request/partial", function(params)
      if active and active.id == params.request_id and active.operation == "ask" then active.streamed = active.streamed .. params.text; ui.append(active.id, normalize.apply(params.text, punctuation), "Claude answer", active.origin) end
    end)
    bridge.on("request/error", function(params)
      if active and active.id == params.request_id then ui.finish(active.id, params.message, "Claude error", active.origin); target.clear_highlight(active.target); active = nil end
    end)
    bridge.on("context/reset", function() context.reset() end)
    bridge.on("request/complete", function(params)
      if not active or active.id ~= params.request_id then return end
      local current = active
      context.accept(current.candidate)
      if current.operation == "ask" then
        ui.finish(current.id, normalize.apply(params.text, punctuation), "Claude answer", current.origin)
        if current.target then target.remember_ask(current.target) else target.break_ask_chain() end
      else
        local replacements, message, needs_input = envelope(params.text, current.target)
        if not replacements then ui.finish(current.id, normalize.apply(message .. (needs_input and "" or "\n\nRaw response:\n" .. params.text), punctuation), "Claude result", current.origin)
        else
          local ok, apply_error = target.apply(current.target, replacements)
          if not ok then ui.finish(current.id, apply_error .. "\n\n" .. params.text, "Claude result", current.origin) else notify(current.operation .. " complete") end
        end
      end
      target.clear_highlight(current.target)
      active = nil
    end)
    vim.api.nvim_create_autocmd("VimLeavePre", { callback = bridge.stop })
    initialized = true
  end
  for _, mapping in ipairs(installed_mappings) do pcall(vim.keymap.del, mapping.mode, mapping.lhs) end
  installed_mappings = {}
  if config.current.keys ~= false then
    local keys = config.current.keys
    install_mapping({ "n", "x" }, keys.replace, actions.replace, "Claude replace", explicit.replace ~= nil)
    install_mapping({ "n", "x" }, keys.replace_short, actions.replace, "Claude replace", explicit.replace_short ~= nil)
    install_mapping({ "n", "x" }, keys.ask, actions.ask, "Claude ask", explicit.ask ~= nil)
    install_mapping("n", keys.generate, actions.generate, "Claude generate", explicit.generate ~= nil)
    install_mapping("i", keys.generate_insert, actions.generate, "Claude generate", explicit.generate_insert ~= nil)
    for _, name in ipairs({ "model", "model_manual", "clear", "new", "sticky", "save", "info", "list" }) do install_mapping("n", keys[name], actions[name], "Claude " .. name:gsub("_", " "), explicit[name] ~= nil) end
  end
end

return M
