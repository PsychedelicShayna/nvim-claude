local M = {}
local api = vim.api
local rpc = require("nvim-claude.rpc")
local targets = require("nvim-claude.targets")
local ui = require("nvim-claude.ui")

local state = {
  epoch = 0, mappings = {}, remembered = {}, ask_target = nil,
  last_action = nil, active = nil, transition = false, prompt = nil,
  config = { model = "claude-haiku-5-5", effort = "low", context_limit_tokens = 100000 },
  policy = "allow",
}
local punctuation = {
  ["—"] = "-", ["–"] = "-", ["‘"] = "'", ["’"] = "'",
  ["“"] = '"', ["”"] = '"', ["…"] = "...", [" "] = " ",
}
local presets = {
  50, 90, 100, 124, 150, 164, 200, 224, 256, 258, 274, 278, 300, 374,
  378, 384, 412, 456, 500, 512, 600, 650, 700, 750, 800, 850, 900, 950, 980,
}

local function notify(text, level)
  if type(text) == "table" then text = text.message or vim.inspect(text) end
  vim.notify(tostring(text), level or vim.log.levels.INFO, { title = "nvim-claude" })
end

local function error_message(err)
  if type(err) == "table" then return tostring(err.message or vim.inspect(err)) end
  return tostring(err)
end

local function normalize(text, policy)
  if policy == "allow" then return text end
  for char, replacement in pairs(state.punctuation or punctuation) do
    text = text:gsub(vim.pesc(char), function()
      return policy == "remove" and "" or replacement
    end)
  end
  return text
end

local function remember_config(result)
  if type(result) ~= "table" then return end
  if type(result.config) == "table" then state.config = result.config end
end

local function request(method, params, done)
  return rpc.request(method, params or {}, function(err, result)
    if err then notify(error_message(err), vim.log.levels.ERROR)
    else remember_config(result) end
    if done then done(err, result) end
  end)
end

local function busy()
  if state.active or state.transition then
    notify("Conversation is busy; your draft is retained. Use :NvClaude cancel first.", vim.log.levels.WARN)
    return true
  end
  return false
end

local function title(operation)
  local model = state.config.model or "claude-haiku-5-5"
  if state.config.resolved_model and state.config.resolved_model ~= model then
    model = model .. " → " .. state.config.resolved_model
  end
  return operation .. " · " .. model
end

local function end_ask_chain()
  if state.ask_target then targets.highlight(state.ask_target, false) end
  state.ask_target = nil
  state.last_action = nil
end

local function reusable_ask(buf)
  local target = state.ask_target
  if state.last_action == "selected-ask" and target and target.buf == buf and targets.valid(target) then
    return target
  end
  end_ask_chain()
end

local function valid_replacements(result, wire)
  if type(result) ~= "table" then return nil, "Invalid edit response: expected an object" end
  if result.status == "needs_input" then
    if type(result.message) ~= "string" or (result.replacements ~= nil
      and (type(result.replacements) ~= "table" or next(result.replacements) ~= nil)) then
      return nil, "Invalid needs_input response"
    end
    return nil, result.message, true
  end
  if result.status ~= "ok" or type(result.replacements) ~= "table" then
    return nil, "Invalid edit response: expected ok and replacements"
  end
  local expected, seen, decoded = {}, {}, {}
  for _, item in ipairs(wire) do expected[item.id] = item end
  for key, replacement in pairs(result.replacements) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      return nil, "Invalid replacement list"
    end
    if type(replacement) ~= "table" or type(replacement.id) ~= "string"
      or type(replacement.text) ~= "string" or not expected[replacement.id] or seen[replacement.id] then
      return nil, "Invalid edit response: duplicate, unknown, or malformed target"
    end
    if expected[replacement.id].block and replacement.text:find("\n", 1, true) then
      return nil, "Invalid blockwise replacement: a segment contains a newline"
    end
    seen[replacement.id] = true
    decoded[#decoded + 1] = { id = replacement.id, text = replacement.text }
  end
  for id in pairs(expected) do
    if not seen[id] then return nil, "Invalid edit response: missing target " .. id end
  end
  if #decoded ~= #wire then return nil, "Invalid edit response: wrong replacement count" end
  return decoded
end

local function retained_result(active, message, result)
  local text = message
  if result and type(result.text) == "string" then
    text = text .. "\n\nRaw result:\n" .. result.text
  elseif result then
    text = text .. "\n\n" .. vim.inspect(result)
  end
  local answer = active.answer or ui.answer({ origin = active.origin, title = title("Result not applied") })
  answer:set(text, title("Result not applied"))
  state.last_answer = answer
end

local function submit(operation, target, origin, instruction)
  if busy() then return false end
  if not instruction:find("%S") then
    notify("Enter an instruction before submitting", vim.log.levels.WARN)
    return false
  end
  local wire
  local envelope = { operation = operation, instruction = instruction }
  if target then
    if not targets.valid(target) then
      notify("The captured target changed. Close this prompt and select it again.", vim.log.levels.WARN)
      return false
    end
    wire = targets.envelope(target)
    if not wire or #wire == 0 then
      notify("The captured target is no longer available", vim.log.levels.ERROR)
      return false
    end
    local buf = target.buf
    envelope.targets = wire
    envelope.document = { id = "buffer-" .. buf, filetype = vim.bo[buf].filetype }
    envelope.context = {
      kind = "snapshot", revision = tostring(api.nvim_buf_get_changedtick(buf)),
      text = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n"),
    }
  end
  if operation == "ask" and target then
    state.ask_target, state.last_action = target, "selected-ask"
  else
    end_ask_chain()
    state.last_action = operation
  end
  local active = {
    epoch = state.epoch, operation = operation, target = target, origin = origin,
    wire = wire, raw = "", policy = state.policy,
  }
  state.active = active
  if operation == "ask" then
    active.answer = ui.answer({ origin = origin, title = title("Ask · preparing") })
    state.last_answer = active.answer
  end
  notify(title(operation) .. " · preparing conversation")
  active.id = rpc.request("turn", { epoch = active.epoch, envelope = envelope }, function(err, result)
    if state.active ~= active or state.epoch ~= active.epoch then return end
    state.active = nil
    if target then targets.highlight(target, false) end
    if err then
      local message = error_message(err)
      retained_result(active, message, result or (active.raw ~= "" and { text = active.raw } or nil))
      notify(message, vim.log.levels.ERROR)
      return
    end
    remember_config(result and result.info)
    if operation == "ask" then
      if type(result) ~= "table" or type(result.text) ~= "string" then
        retained_result(active, "Invalid ask result", result)
        return
      end
      active.answer:set(normalize(result.text, active.policy), title("Ask · complete"))
      return
    end
    local replacements, reason, clarification = valid_replacements(result, wire)
    if not replacements then
      if clarification then
        local answer = ui.answer({ origin = origin, title = title("Input needed"), text = normalize(reason, active.policy) })
        state.last_answer = answer
      else retained_result(active, reason, result) end
      return
    end
    for _, item in ipairs(replacements) do item.text = normalize(item.text, active.policy) end
    local ok, apply_error = targets.apply(target, replacements)
    if not ok then
      retained_result(active, "Result was not applied: " .. tostring(apply_error), result)
      return
    end
    state.remembered[target.buf] = target
    local empty = operation == "generate" and #replacements == 1 and replacements[1].text == ""
    notify(title(operation) .. (empty and " · complete, empty insertion" or " · applied"))
  end)
  return true
end

local function visual_mode()
  local mode = api.nvim_get_mode().mode
  if mode == "v" or mode == "V" or mode == "\22" then return mode end
end

function M.invoke(operation, options)
  options = options or {}
  if state.prompt and not state.prompt.closed then
    if api.nvim_win_is_valid(state.prompt.win) then api.nvim_set_current_win(state.prompt.win) end
    notify("Finish or dismiss the existing prompt first", vim.log.levels.WARN)
    return
  end
  local buf, origin = api.nvim_get_current_buf(), api.nvim_get_current_win()
  local mode = options.mode or visual_mode()
  local target, err
  if operation == "generate" then
    target, err = targets.capture(buf, "generate")
    end_ask_chain()
    state.last_action = "generate"
  elseif mode then
    target, err = targets.capture(buf, mode)
    if operation == "replace" then
      end_ask_chain()
      state.last_action = "replace"
      if target then state.remembered[buf] = target end
    end
  elseif operation == "replace" then
    target = state.remembered[buf]
    if not target or not targets.valid(target) then err = "Select text before requesting replacement"; target = nil end
    end_ask_chain()
    state.last_action = "replace"
  elseif options.previous then
    target = reusable_ask(buf)
    if not target then err = "No valid selected-ask target in this buffer" end
  elseif options.followup then
    target = reusable_ask(buf)
  else
    end_ask_chain()
  end
  if err then notify(err, vim.log.levels.WARN); return end
  if mode and target then state.remembered[buf] = target end
  if target then target.origin = origin; targets.highlight(target, true) end
  if mode then
    vim.cmd("normal! \27")
  end
  local prompt
  prompt = ui.prompt({
    origin = origin, title = title(operation),
    on_submit = function(text) return submit(operation, target, origin, text) end,
    on_close = function()
      if target and not (state.active and state.active.target == target) then targets.highlight(target, false) end
      if target and state.remembered[target.buf] ~= target and state.ask_target ~= target
        and not (state.active and state.active.target == target) then targets.dispose(target) end
      if state.prompt == prompt then state.prompt = nil end
    end,
  })
  state.prompt = prompt
  if not state.initialized and not state.initializing and not state.active and not state.transition then
    state.initializing = true
    request("initialize", {}, function(err)
      state.initializing = false
      state.initialized = not err
      if not err and not prompt.closed then prompt:title(title(operation)) end
    end)
  end
end

function M.cancel(done)
  state.epoch = state.epoch + 1
  local active = state.active
  state.active = nil
  if active then
    if active.target then targets.highlight(active.target, false) end
    if active.answer then
      active.answer:set(normalize(active.raw, active.policy), title("Ask · canceled"))
    elseif active.raw ~= "" then
      retained_result(active, "Request canceled; no partial edit applied", { text = active.raw })
    end
  end
  state.transition = true
  request("cancel", { epoch = state.epoch }, function(err)
    state.transition = false
    if done then done(err) elseif not err then notify("Request canceled; no partial edit applied") end
  end)
end

local function transition(method, params)
  if state.transition then notify("A conversation transition is already pending", vim.log.levels.WARN); return end
  M.cancel(function(err)
    if err then return end
    state.transition = true
    request(method, params or {}, function(change_err)
      state.transition = false
      if not change_err then end_ask_chain(); notify("Conversation " .. method .. " complete") end
    end)
  end)
end

local function configure(params)
  if busy() then return end
  state.transition = true
  request("configure", params, function(err, result)
    state.transition = false
    if not err then
      remember_config(result)
      notify(title("Model configured") .. "\n" .. vim.inspect(state.config))
    end
  end)
end

function M.model_manual()
  if busy() then return end
  vim.ui.input({ prompt = "Model expression: ", default = state.config.model }, function(value)
    if value and value ~= "" then configure({ expression = value }) end
  end)
end

local function model_id(model)
  if type(model) == "string" then return model end
  return model.id or model.value or model.model
end

local function efforts(model)
  if type(model) ~= "table" then return nil end
  return model.supported_effort_levels or model.supportedEffortLevels or model.effort_levels or model.efforts
end

function M.model()
  if busy() then return end
  request("models", {}, function(err, result)
    if err then return end
    local models = result.models or result
    if type(models) ~= "table" or #models == 0 then
      notify("Runtime model discovery is unavailable. Use :NvClaude model manual for an explicit slug.", vim.log.levels.WARN)
      return
    end
    vim.ui.select(models, {
      prompt = "Runtime model", format_item = function(item)
        if type(item) == "string" then return item end
        local id = model_id(item) or "unknown runtime model"
        local name = item.displayName or item.display_name or item.name
        return name and name ~= id and name .. " · " .. id or id
      end,
    }, function(model)
      if not model then return end
      local id = model_id(model)
      if not id then notify("Runtime announced a model without an ID", vim.log.levels.ERROR); return end
      local function budget(effort)
        local choices = { { label = "model default", value = vim.NIL } }
        for _, n in ipairs(presets) do choices[#choices + 1] = { label = n .. "k", value = n * 1000 } end
        vim.ui.select(choices, {
          prompt = "Local context budget · cannot exceed physical model window",
          format_item = function(item) return item.label end,
        }, function(choice)
          if not choice then return end
          configure({ model = id, effort = effort or vim.NIL, context_limit_tokens = choice.value })
        end)
      end
      local supported = efforts(model)
      if type(supported) == "table" and #supported > 0 then
        vim.ui.select(supported, {
          prompt = "Supported effort", format_item = function(item)
            return type(item) == "table" and (item.name or item.value or item.id) or tostring(item)
          end,
        }, function(effort)
          if effort ~= nil then
            if type(effort) == "table" then effort = effort.value or effort.id or effort.name end
            budget(effort)
          end
        end)
      else
        budget(nil)
      end
    end)
  end)
end

function M.info()
  request("info", {}, function(err, result)
    if err then return end
    local text = type(result) == "string" and result or vim.inspect(result)
    state.last_answer = ui.answer({ origin = api.nvim_get_current_win(), title = "Claude information", text = text, enter = true })
  end)
end

function M.list()
  request("list", {}, function(err, result)
    if err then return end
    local list = result.conversations or result.sessions or result
    if type(list) ~= "table" or #list == 0 then notify("No saved conversations"); return end
    table.sort(list, function(a, b) return tostring(a.created_at or "") > tostring(b.created_at or "") end)
    vim.ui.select(list, {
      prompt = "Resume saved conversation", format_item = function(item)
        local stamp = tonumber(item.created_at)
        local date = stamp and os.date("%y:%m:%d:%H:%M:%S", stamp) or tostring(item.created_at or "")
        local name = item.title or (date .. " - " .. tostring(item.first_prompt or ""))
        return name:gsub("\n", " ") .. " [" .. tostring(item.id) .. "]"
      end,
    }, function(item) if item then transition("resume", { id = item.id }) end end)
  end)
end

function M.system_modify()
  request("system", { get = true }, function(err, result)
    if err then return end
    ui.system(result.text, function(text, done)
      if busy() then done(false); return end
      state.transition = true
      request("system", { text = text }, function(save_err)
        state.transition = false
        done(not save_err)
        if not save_err then notify("System prompt updated for the next turn; history retained") end
      end)
    end)
  end)
end

local commands = {
  "ask", "replace", "generate", "model", "new", "clear", "save", "sticky", "compact",
  "list", "resume", "info", "cancel", "system", "watermarks", "login", "update",
}
local subcommands = {
  ask = { "previous" }, model = { "manual" }, sticky = { "on", "off" },
  system = { "modify", "default" }, watermarks = { "allow", "remove", "replace" },
}

function M.command(args)
  local words = type(args) == "table" and args or vim.split(args or "", "%s+", { trimempty = true })
  local command, arg = words[1] or "ask", words[2]
  if command == "ask" then
    if arg and arg ~= "previous" then notify("Usage: NvClaude ask [previous]", vim.log.levels.ERROR); return end
    M.invoke("ask", { previous = arg == "previous" })
  elseif command == "replace" or command == "generate" then M.invoke(command)
  elseif command == "model" then
    if arg == "manual" then M.model_manual()
    elseif arg then configure({ expression = table.concat(words, " ", 2) }) else M.model() end
  elseif command == "new" or command == "clear" then transition(command)
  elseif command == "resume" then
    if arg then transition("resume", { id = arg }) else M.list() end
  elseif command == "cancel" then M.cancel()
  elseif command == "info" then M.info()
  elseif command == "list" then M.list()
  elseif command == "sticky" then
    if arg and arg ~= "on" and arg ~= "off" then notify("Usage: NvClaude sticky [on|off]", vim.log.levels.ERROR); return end
    if not busy() then
      state.transition = true
      request("sticky", { mode = arg or "toggle" }, function(err, result)
        state.transition = false
        if not err then notify(result) end
      end)
    end
  elseif command == "save" or command == "compact" then
    if not busy() then
      state.transition = true
      notify(command == "compact" and "Compacting conversation" or "Saving conversation")
      request(command, {}, function(err, result)
        state.transition = false
        if not err then notify(result) end
      end)
    end
  elseif command == "system" then
    if arg == "modify" then M.system_modify()
    elseif arg == "default" then
      if not busy() then
        state.transition = true
        request("system", { default = true }, function(err)
          state.transition = false
          if not err then notify("Default system prompt restored") end
        end)
      end
    else notify("Usage: NvClaude system modify|default", vim.log.levels.ERROR) end
  elseif command == "watermarks" then
    if arg == "allow" or arg == "remove" or arg == "replace" then state.policy = arg
    elseif arg then notify("Usage: NvClaude watermarks allow|remove|replace", vim.log.levels.ERROR); return end
    notify("Punctuation normalization: " .. state.policy)
  elseif command == "login" then rpc.login()
  elseif command == "update" then
    if not busy() then
      state.transition = true
      request("update", {}, function(err, result)
        state.transition = false
        state.initialized = false
        if not err then notify(result) end
      end)
    end
  else notify("Unknown NvClaude command: " .. command, vim.log.levels.ERROR) end
end

function M.complete(lead, line)
  local before = line:sub(1, #line - #lead)
  local words = vim.split(before, "%s+", { trimempty = true })
  local choices = #words <= 1 and commands or subcommands[words[2]] or {}
  return vim.tbl_filter(function(item) return item:sub(1, #lead) == lead end, choices)
end

local defaults = {
  replace = { "<leader>cc", { "n", "x" } }, replace_short = { "<leader>c", { "n", "x" } },
  ask = { "<leader>ca", { "n", "x" } }, generate = { "<leader>ci", { "n" } },
  generate_insert = { false, { "i" } }, model = { "<leader>cm", { "n" } },
  model_manual = { "<leader>cM", { "n" } }, clear = { "<leader>cC", { "n" } },
  new = { "<leader>cn", { "n" } }, sticky = { "<leader>cS", { "n" } },
  save = { "<leader>cs", { "n" } }, info = { "<leader>cx", { "n" } }, list = { "<leader>cl", { "n" } },
}

local function install_mappings(keys)
  for _, mapping in ipairs(state.mappings) do
    for _, current in ipairs(api.nvim_get_keymap(mapping.mode)) do
      if current.callback == mapping.callback then
        pcall(vim.keymap.del, mapping.mode, current.lhs)
      end
    end
  end
  state.mappings = {}
  if keys == false then return end
  keys = keys or {}
  for action, spec in pairs(defaults) do
    local configured = keys[action]
    local lhs = configured == nil and spec[1] or configured
    if type(lhs) == "string" then
      for _, mode in ipairs(spec[2]) do
        local mapping = vim.fn.maparg(lhs, mode, false, true)
        if configured ~= nil or vim.tbl_isempty(mapping) then
          local callback = function()
            if action == "replace" or action == "replace_short" then M.invoke("replace")
            elseif action == "ask" then M.invoke("ask", { followup = true })
            elseif action == "generate" or action == "generate_insert" then M.invoke("generate")
            else M.command({ action }) end
          end
          vim.keymap.set(mode, lhs, callback, { silent = true, desc = "Claude " .. action })
          state.mappings[#state.mappings + 1] = { mode = mode, lhs = lhs, callback = callback }
        end
      end
    end
  end
end

function M.setup(opts)
  opts = opts or {}
  for _, key in ipairs({ "model", "effort", "context_limit_tokens" }) do
    if opts[key] ~= nil then state.config[key] = opts[key] end
  end
  if opts.watermarks then
    if opts.watermarks ~= "allow" and opts.watermarks ~= "remove" and opts.watermarks ~= "replace" then
      error("nvim-claude: watermarks must be allow, remove, or replace")
    end
    state.policy = opts.watermarks
  end
  state.punctuation = vim.tbl_extend("force", punctuation, opts.punctuation_map or {})
  rpc.setup(opts)
  rpc.on_event(function(event)
    local active = state.active
    if not active or event.epoch ~= active.epoch or event.request_id ~= active.id then return end
    if event.kind == "text" and type(event.text) == "string" then
      active.raw = active.raw .. event.text
      if active.answer then active.answer:set(normalize(active.raw, active.policy), title("Ask · streaming")) end
    elseif event.kind == "status" then
      local status = event.text or event.status or "running"
      if active.answer then active.answer:set(normalize(active.raw, active.policy), title("Ask · " .. status)) end
      notify(title(active.operation) .. " · " .. status)
    end
  end)
  api.nvim_create_user_command("NvClaude", function(args) M.command(args.fargs) end, {
    nargs = "*", force = true, complete = function(lead, line) return M.complete(lead, line) end,
    desc = "Cursor-local Claude editing and questions",
  })
  install_mappings(opts.keys)
  local group = api.nvim_create_augroup("NvimClaudeLifecycle", { clear = true })
  api.nvim_create_autocmd("VimLeavePre", { group = group, callback = function() rpc.stop() end })
  api.nvim_create_autocmd("BufEnter", {
    group = group, callback = function(args)
      if state.ask_target and state.ask_target.buf ~= args.buf then
        if not vim.b[args.buf].nvim_claude_ui and vim.bo[args.buf].buftype == "" then end_ask_chain() end
      end
    end,
  })
  return M
end

return M
