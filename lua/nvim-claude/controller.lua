local bridge = require("nvim-claude.bridge")
local config_module = require("nvim-claude.config")
local context = require("nvim-claude.context")
local target = require("nvim-claude.target")
local ui = require("nvim-claude.ui")
local util = require("nvim-claude.util")

local M = {}
local state = {
  config = nil,
  system_prompt = nil,
  default_system_prompt = nil,
  active = nil,
  sequence = 0,
  runtime_models = {},
}

local function command_params(extra)
  return vim.tbl_extend("force", {
    config = state.config,
    system_prompt = state.system_prompt,
    cache_ttl_seconds = state.config.cache_ttl_seconds,
  }, extra or {})
end

local function show_error(message, origin, text)
  local body = text and (message .. "\n\nGenerated result:\n\n" .. text) or message
  ui.show_text("Claude error", body, origin, "markdown")
end

local function edit_result(raw, request_target)
  local ok, decoded = pcall(vim.json.decode, raw)
  if not ok or type(decoded) ~= "table" then
    return nil, "Claude returned an invalid edit envelope"
  end
  if decoded.status == "needs_input" then
    if type(decoded.message) ~= "string" or decoded.message == "" or decoded.replacements ~= nil then
      return nil, "Claude returned an invalid needs_input envelope"
    end
    return { needs_input = decoded.message }
  end
  if decoded.status ~= "ok" or type(decoded.replacements) ~= "table" then
    return nil, "Claude returned an unknown edit status"
  end
  local expected = {}
  for _, segment in ipairs(request_target.segments) do
    expected[segment.id] = true
  end
  local seen, replacements = {}, {}
  for _, replacement in ipairs(decoded.replacements) do
    if type(replacement) ~= "table" or type(replacement.id) ~= "string" or type(replacement.text) ~= "string" then
      return nil, "Claude returned a malformed replacement"
    end
    if not expected[replacement.id] or seen[replacement.id] then
      return nil, "Claude returned an unknown or duplicate target ID"
    end
    if request_target.kind == "block" and replacement.text:find("\n", 1, true) then
      return nil, "Claude returned a multiline blockwise replacement"
    end
    seen[replacement.id] = true
    table.insert(replacements, {
      id = replacement.id,
      text = util.normalize(replacement.text, state.config.punctuation, state.config.punctuation_map),
    })
  end
  for id in pairs(expected) do
    if not seen[id] then
      return nil, "Claude omitted target " .. id
    end
  end
  return { replacements = replacements }
end

local function complete_request(active, result, err)
  if state.active ~= active or active.canceled then
    return
  end
  state.active = nil
  if err then
    context.invalidate(active.buffer)
    target.clear(active.target)
    local message = util.display_error(err)
    if active.answer then
      ui.replace(active.answer, message)
      ui.set_title(active.answer, "Claude error")
    else
      show_error(message, active.origin_win)
    end
    return
  end

  if active.buffer and active.context_state then
    context.confirm(active.buffer, active.context_state)
  end
  if active.operation == "ask" then
    local presented = util.normalize(result.text or "", state.config.punctuation, state.config.punctuation_map)
    ui.replace(active.answer, presented)
    ui.set_title(active.answer, "Claude answer")
    if active.target then
      target.dim(active.target)
      target.remember_ask(active.target)
    else
      target.content_action(active.buffer or vim.api.nvim_get_current_buf(), "general_ask")
    end
    return
  end

  local parsed, parse_error = edit_result(result.text or "", active.target)
  if not parsed then
    target.clear(active.target)
    show_error(parse_error, active.origin_win, result.text)
    return
  end
  if parsed.needs_input then
    target.dim(active.target)
    if active.operation == "replace" then
      target.remember_replace(active.target)
    end
    ui.show_text("Claude needs input", parsed.needs_input, active.origin_win, "markdown")
    return
  end

  local applied, apply_error = target.apply(active.target, parsed.replacements)
  if not applied then
    target.clear(active.target)
    show_error(apply_error, active.origin_win, result.text)
    return
  end
  target.dim(applied)
  if active.operation == "replace" then
    target.remember_replace(applied)
  else
    target.clear(applied)
    target.content_action(active.buffer, "generate")
  end
  util.notify(active.operation == "replace" and "replacement applied" or "text inserted")
end

local function dispatch(operation, request_target, instruction, origin_win)
  local buf = request_target and request_target.buffer or vim.api.nvim_get_current_buf()
  local targets, target_error
  if request_target then
    targets, target_error = target.request_targets(request_target)
    if not targets then
      target.clear(request_target)
      show_error(target_error, origin_win)
      return
    end
  end
  local request_context, context_state, context_error = context.build(
    buf, request_target, instruction, state.config, state.system_prompt
  )
  if context_error then
    target.clear(request_target)
    show_error(context_error, origin_win)
    return
  end

  state.sequence = state.sequence + 1
  local request_id = ("nvim-%d-%d"):format(vim.fn.getpid(), state.sequence)
  local payload = { operation = operation, instruction = instruction }
  if request_target then
    payload.document = {
      id = "buffer-" .. buf,
      filetype = vim.bo[buf].filetype,
      path = vim.api.nvim_buf_get_name(buf) ~= "" and vim.api.nvim_buf_get_name(buf) or nil,
    }
    payload.context = request_context
    payload.targets = targets
  end
  local answer
  if operation == "ask" then
    answer = ui.answer({ title = "Claude · waiting", origin_win = origin_win })
  end
  local active = {
    request_id = request_id,
    operation = operation,
    target = request_target,
    buffer = buf,
    context_state = context_state,
    origin_win = origin_win,
    answer = answer,
    canceled = false,
  }
  state.active = active
  if request_target then
    target.status(request_target, "provisioning")
  end
  bridge.call("conversation/request", command_params({
    request_id = request_id,
    instruction = instruction,
    payload = payload,
  }), function(result, err)
    complete_request(active, result, err)
  end)
end

local function open_prompt(operation, request_target)
  if state.active then
    util.notify("the conversation is busy; cancel it or wait before sending another instruction", vim.log.levels.WARN)
    if request_target then target.clear(request_target) end
    return
  end
  local origin = request_target and request_target.origin_win or vim.api.nvim_get_current_win()
  ui.prompt({
    origin_win = origin,
    title = operation .. " · " .. config_module.format_model(state.config),
    on_submit = function(text)
      if vim.trim(text) == "" then
        if request_target then target.clear(request_target) end
        util.notify("instruction is empty", vim.log.levels.WARN)
        return
      end
      dispatch(operation, request_target, text, origin)
    end,
    on_cancel = function()
      if request_target then target.clear(request_target) end
    end,
  })
end

function M.replace()
  local mode = vim.fn.mode(1):sub(1, 1)
  local request_target, err
  if mode == "v" or mode == "V" or mode == "\22" then
    request_target, err = target.capture_visual("replace")
  else
    request_target, err = target.previous_replace(vim.api.nvim_get_current_buf())
  end
  if not request_target then
    util.notify(err or "Select text before using replacement", vim.log.levels.WARN)
    return
  end
  open_prompt("replace", request_target)
end

function M.generate(mode)
  open_prompt("generate", target.capture_insert(mode or "n"))
end

function M.ask(previous)
  local mode = vim.fn.mode(1):sub(1, 1)
  local request_target, err
  if mode == "v" or mode == "V" or mode == "\22" then
    request_target, err = target.capture_visual("ask")
  elseif previous then
    request_target, err = target.previous_ask(vim.api.nvim_get_current_buf(), true)
  else
    request_target = target.previous_ask(vim.api.nvim_get_current_buf(), false)
  end
  if err then
    util.notify(err, vim.log.levels.WARN)
    return
  end
  open_prompt("ask", request_target)
end

function M.cancel()
  local active = state.active
  if not active then
    util.notify("there is no active request", vim.log.levels.WARN)
    return
  end
  active.canceled = true
  state.active = nil
  bridge.notify("conversation/cancel", { request_id = active.request_id })
  target.clear(active.target)
  if active.answer then
    ui.set_title(active.answer, "Claude · canceled")
  end
  util.notify("request canceled")
end

function M.on_notification(method, params)
  local active = state.active
  if not active or params.request_id ~= active.request_id then
    return
  end
  if method == "stream" and active.answer then
    ui.append(active.answer, util.normalize(params.text or "", state.config.punctuation, state.config.punctuation_map))
  elseif method == "session" then
    local label = params.state == "continued" and "continued" or "new session"
    if active.target then target.status(active.target, label) end
    if active.answer then ui.set_title(active.answer, "Claude · " .. label) end
  elseif method == "status" then
    if active.target then target.status(active.target, params.state) end
    if active.answer then ui.set_title(active.answer, "Claude · " .. params.state) end
  end
end

local function session_command(action, extra, callback)
  bridge.call("conversation/command", command_params(vim.tbl_extend("force", { action = action }, extra or {})), function(result, err)
    if err then
      util.notify(util.display_error(err), vim.log.levels.ERROR)
      return
    end
    if action == "new" or action == "clear" or action == "resume" or action == "compact" then
      context.invalidate()
      target.invalidate_baselines_state()
    end
    if callback then callback(result) else util.notify(action .. " completed") end
  end)
end

function M.new() session_command("new") end
function M.clear() session_command("clear") end
function M.save() session_command("save", nil, function() util.notify("conversation saved") end) end
function M.compact()
  state.sequence = state.sequence + 1
  session_command("compact", { request_id = "compact-" .. state.sequence }, function() util.notify("conversation compacted") end)
end

function M.sticky(value)
  session_command("sticky", { value = value }, function(result)
    util.notify("sticky mode " .. (result.sticky and "on" or "off"))
  end)
end

function M.list()
  session_command("list", nil, function(result)
    local conversations = result.conversations or {}
    if #conversations == 0 then
      util.notify("there are no saved conversations")
      return
    end
    vim.ui.select(conversations, {
      prompt = "Resume Claude conversation",
      format_item = function(item)
        local stamp = os.date("%y:%m:%d:%H:%M:%S", item.created or 0)
        local title = (item.first_prompt or ""):gsub("\n", " ")
        if #title > 72 then title = title:sub(1, 69) .. "..." end
        return stamp .. " - " .. title .. " [" .. item.id:sub(1, 8) .. "]"
      end,
    }, function(item)
      if item then session_command("resume", { id = item.id }, function() util.notify("conversation resumed") end) end
    end)
  end)
end

function M.info()
  bridge.call("runtime/info", command_params(), function(result, err)
    if err then util.notify(util.display_error(err), vim.log.levels.ERROR); return end
    local conversation = result.conversation or {}
    local usage = result.context_usage or {}
    local lines = {
      "Model: " .. tostring(conversation.model or state.config.model),
      "Effort: " .. tostring(conversation.effort or state.config.effort or "runtime default"),
      "Local budget: " .. tostring(state.config.context_limit_tokens or "model default"),
      "Context occupancy: " .. tostring(usage.totalTokens or "unavailable"),
      "Cumulative usage: reported after each completed request",
      "Retention: " .. (conversation.saved and "saved" or "ephemeral") .. (result.sticky and " (sticky)" or ""),
      "SDK: " .. tostring(result.sdk_version),
      "Bundled CLI: " .. tostring(result.cli_version or "unavailable"),
      "Python: " .. tostring(result.python_version),
      "Cache estimate: " .. tostring((result.cache or {}).ttl_seconds or "unknown") .. " seconds (configured estimate)",
      "No-tools configuration: verified on bridge connection",
    }
    ui.show_text("nvim-claude info", table.concat(lines, "\n"), vim.api.nvim_get_current_win(), "text")
  end)
end

local function pick_budget(pending)
  local items = { { label = "model default", value = nil } }
  for _, value in ipairs(config_module.context_presets) do
    table.insert(items, { label = (value / 1000) .. "k", value = value })
  end
  vim.ui.select(items, { prompt = "Context budget", format_item = function(item) return item.label end }, function(item)
    if not item then return end
    pending.context_limit_tokens = item.value
    state.config.model = pending.model
    state.config.effort = pending.effort
    state.config.context_limit_tokens = pending.context_limit_tokens
    context.invalidate()
    util.notify("model set to " .. config_module.format_model(state.config))
  end)
end

function M.model_picker()
  bridge.call("models/list", command_params(), function(result, err)
    if err then util.notify(util.display_error(err), vim.log.levels.ERROR); return end
    local models = result.models or {}
    state.runtime_models = {}
    for _, item in ipairs(models) do state.runtime_models[item.id] = true end
    if #models == 0 then
      util.notify("the runtime did not announce a model catalogue; use :NvClaude model manual", vim.log.levels.WARN)
      return
    end
    vim.ui.select(models, { prompt = "Claude model", format_item = function(item) return item.label or item.id end }, function(model)
      if not model then return end
      local pending = { model = model.id, effort = nil, context_limit_tokens = state.config.context_limit_tokens }
      if model.efforts and #model.efforts > 0 then
        vim.ui.select(model.efforts, { prompt = "Reasoning effort" }, function(effort)
          if not effort then return end
          pending.effort = effort
          pick_budget(pending)
        end)
      else
        pick_budget(pending)
      end
    end)
  end)
end

function M.model_manual(expression)
  local function apply(value)
    local parsed, err = config_module.parse_model_expression(value, state.config, state.runtime_models)
    if not parsed then util.notify(err, vim.log.levels.ERROR); return end
    state.config.model = parsed.model
    state.config.effort = parsed.effort
    state.config.context_limit_tokens = parsed.context_limit_tokens
    context.invalidate()
    util.notify("model set to " .. config_module.format_model(state.config))
  end
  if expression and expression ~= "" then apply(expression); return end
  vim.ui.input({ prompt = "Claude model expression: ", default = config_module.format_model(state.config) }, function(value)
    if value then apply(value) end
  end)
end

function M.watermarks(policy)
  if policy ~= "allow" and policy ~= "remove" and policy ~= "replace" then
    util.notify("watermarks expects allow, remove, or replace", vim.log.levels.ERROR)
    return
  end
  state.config.punctuation = policy
  util.notify("punctuation normalization set to " .. policy)
end

function M.system_modify()
  local buf = vim.api.nvim_create_buf(true, true)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "text"
  vim.api.nvim_buf_set_name(buf, "nvim-claude://system-prompt")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(state.system_prompt, "\n", { plain = true }))
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      state.system_prompt = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      vim.bo[buf].modified = false
      util.notify("system prompt updated for subsequent requests")
    end,
  })
end

function M.system_default()
  state.system_prompt = state.default_system_prompt
  util.notify("system prompt restored for this Neovim session")
end

function M.login()
  bridge.call("runtime/login", {}, function(result, err)
    if err then util.notify(util.display_error(err), vim.log.levels.ERROR); return end
    if not result.command then util.notify("bundled Claude login command was not found", vim.log.levels.ERROR); return end
    vim.cmd("botright new")
    vim.bo.buftype = "nofile"
    vim.fn.jobstart({ result.command, "login" }, { term = true })
    vim.cmd("startinsert")
  end)
end

function M.setup(config)
  state.config = config
  state.default_system_prompt = assert(util.read_file(util.plugin_root() .. "/resources/system_prompt.txt"))
  state.system_prompt = state.default_system_prompt
  bridge.setup(config, M.on_notification)
end

function M.shutdown()
  bridge.stop()
end

return M
