local config = require("nvim-claude.config")
local bridge = require("nvim-claude.bridge")
local context = require("nvim-claude.context")
local target = require("nvim-claude.target")
local ui = require("nvim-claude.ui")

local M = {}
local api = vim.api
local state = {
  opts = nil,
  active = nil,
  remembered = {},
  selected_ask = nil,
  last_content_action = nil,
  installed_maps = {},
  setup = false,
  system_prompt = nil,
  models = {},
}

local action_specs = {
  replace = { modes = { "n", "x" }, desc = "Claude replace selection" },
  replace_short = { modes = { "n", "x" }, desc = "Claude replace selection (short)" },
  ask = { modes = { "n", "x" }, desc = "Ask Claude" },
  generate = { modes = { "n" }, desc = "Generate with Claude" },
  generate_insert = { modes = { "i" }, desc = "Generate with Claude in Insert mode" },
  model = { modes = { "n" }, desc = "Choose Claude model" },
  model_manual = { modes = { "n" }, desc = "Enter Claude model expression" },
  clear = { modes = { "n" }, desc = "Clear Claude context" },
  new = { modes = { "n" }, desc = "Start a Claude conversation" },
  sticky = { modes = { "n" }, desc = "Toggle sticky Claude conversations" },
  save = { modes = { "n" }, desc = "Save Claude conversation" },
  info = { modes = { "n" }, desc = "Show Claude session info" },
  list = { modes = { "n" }, desc = "List saved Claude conversations" },
}

local context_presets = {
  50000, 90000, 100000, 124000, 150000, 164000, 200000, 224000, 256000,
  258000, 274000, 278000, 300000, 374000, 378000, 384000, 412000, 456000,
  500000, 512000, 600000, 650000, 700000, 750000, 800000, 850000, 900000,
  950000, 980000,
}

local valid_efforts = { low = true, medium = true, high = true, xhigh = true, max = true }

local function notify(message, level)
  vim.notify("NvClaude: " .. message, level or vim.log.levels.INFO)
end

local function normalize(text)
  local policy = state.opts.punctuation
  if policy == "allow" then return text end
  for character, replacement in pairs(state.opts.punctuation_map) do
    text = text:gsub(vim.pesc(character), policy == "remove" and "" or replacement)
  end
  return text
end

local function target_valid(value)
  local ok = target.valid(value)
  return ok
end

local function selected_target_or_nil()
  local selected = state.selected_ask
  if state.last_content_action ~= "ask_selected" or not selected then return nil end
  if selected.buf ~= api.nvim_get_current_buf() or not target_valid(selected) then
    state.selected_ask = nil
    return nil
  end
  return selected
end

local function remembered_target_or_warn()
  local buf = api.nvim_get_current_buf()
  local value = state.remembered[buf]
  if not value or not target_valid(value) then
    state.remembered[buf] = nil
    notify("select text before replacing it", vim.log.levels.WARN)
    return nil
  end
  return value
end

local function nearby_boundaries(value, item)
  local start_pos = api.nvim_buf_get_extmark_by_id(value.buf, api.nvim_create_namespace("nvim-claude-targets"), item.start_mark, {})
  local end_pos = api.nvim_buf_get_extmark_by_id(value.buf, api.nvim_create_namespace("nvim-claude-targets"), item.end_mark, {})
  if #start_pos == 0 or #end_pos == 0 then return "", "" end
  local start_line = api.nvim_buf_get_lines(value.buf, start_pos[1], start_pos[1] + 1, false)[1] or ""
  local end_line = api.nvim_buf_get_lines(value.buf, end_pos[1], end_pos[1] + 1, false)[1] or ""
  return start_line:sub(math.max(1, start_pos[2] - 39), start_pos[2]), end_line:sub(end_pos[2] + 1, end_pos[2] + 40)
end

local function build_envelope(operation, instruction, value)
  local envelope = { operation = operation, instruction = instruction }
  local pending_baseline
  if value then
    local synchronized = context.build(value, state.opts.context_limit_tokens)
    envelope.document = synchronized.document
    envelope.context = synchronized.context
    envelope.targets = target.envelope_targets(value)
    for index, item in ipairs(value.segments) do
      local before, after = nearby_boundaries(value, item)
      envelope.targets[index].boundary_before = before
      envelope.targets[index].boundary_after = after
    end
    pending_baseline = synchronized.pending_baseline
  end
  return envelope, pending_baseline
end

local function finish_active(active)
  if state.active == active then state.active = nil end
  if active.target then ui.clear_highlight(active.target.buf) end
end

local function request(operation, instruction, value, origin_win)
  if state.active then
    notify("the active conversation is busy; your prompt was not sent", vim.log.levels.WARN)
    return
  end
  local envelope, pending_baseline = build_envelope(operation, instruction, value)
  local active = {
    operation = operation,
    target = value,
    origin_win = origin_win,
    pending_baseline = pending_baseline,
    streamed = "",
    cancelled = false,
  }
  state.active = active
  if operation == "ask" then ui.open_answer(state.opts, "Claude · waiting", origin_win) end
  bridge.call("request", {
    envelope = envelope,
    contextLimitTokens = state.opts.context_limit_tokens,
  }, function(result, err)
    if active.cancelled or state.active ~= active then return end
    if err then
      finish_active(active)
      if operation == "ask" and active.streamed ~= "" then
        ui.answer_append(state.opts, "\n\n[Request failed: " .. err .. "]")
      else
        notify(err, vim.log.levels.ERROR)
      end
      return
    end
    context.accept(active.pending_baseline)
    if operation == "ask" then
      if active.streamed == "" then ui.answer_set(state.opts, "Claude · answer", normalize(result.raw), origin_win) end
      if value then
        state.selected_ask = value
        state.last_content_action = "ask_selected"
      else
        state.selected_ask = nil
        state.last_content_action = "ask_general"
      end
      finish_active(active)
      return
    end

    local decoded, decode_err = target.decode_result(value, result.raw)
    if not decoded then
      ui.answer_set(state.opts, "Claude · invalid edit", result.raw .. "\n\n" .. decode_err, origin_win)
      finish_active(active)
      return
    end
    if decoded.needs_input then
      ui.answer_set(state.opts, "Claude · needs input", normalize(decoded.needs_input), origin_win)
      finish_active(active)
      return
    end
    local applied, apply_err = target.apply(value, decoded.replacements, normalize)
    if not applied then
      ui.answer_set(state.opts, "Claude · edit not applied", result.raw .. "\n\n" .. apply_err, origin_win)
      finish_active(active)
      return
    end
    if operation == "replace" then state.remembered[value.buf] = value end
    state.selected_ask = nil
    state.last_content_action = operation
    finish_active(active)
    notify(operation == "replace" and "replacement applied" or "text inserted")
  end)
end

local function open_operation(operation, value)
  local origin_win = api.nvim_get_current_win()
  if value then ui.highlight_target(value.buf, target.highlight_ranges(value)) end
  local model = state.opts.model or "model default"
  ui.open_prompt(state.opts, operation .. " · " .. model, function(instruction)
    request(operation, instruction, value, origin_win)
  end, origin_win)
end

local function replace()
  local mode = vim.fn.mode(1):sub(1, 1)
  local value = (mode == "v" or mode == "V" or mode == "\022") and target.capture_visual("replace") or remembered_target_or_warn()
  if value then open_operation("replace", value) end
end

local function ask()
  local mode = vim.fn.mode(1):sub(1, 1)
  local value
  if mode == "v" or mode == "V" or mode == "\022" then
    value = target.capture_visual("ask")
  else
    value = selected_target_or_nil()
  end
  open_operation("ask", value)
end

local function ask_general()
  state.selected_ask = nil
  open_operation("ask", nil)
end

local function ask_previous()
  local value = state.selected_ask
  if not value or value.buf ~= api.nvim_get_current_buf() or not target_valid(value) then
    notify("there is no valid selected-ask target in this buffer", vim.log.levels.WARN)
    return
  end
  open_operation("ask", value)
end

local function generate(insert_mode)
  state.selected_ask = nil
  open_operation("generate", target.capture_insert(insert_mode))
end

local function session(action, extra)
  if state.active then
    notify("cancel or finish the active request first", vim.log.levels.WARN)
    return
  end
  local params = vim.tbl_extend("force", { action = action }, extra or {})
  bridge.call("session", params, function(result, err)
    if err then notify(err, vim.log.levels.ERROR); return end
    if action == "new" or action == "clear" or action == "compact" or action == "resume" then
      context.invalidate()
      state.selected_ask = nil
      state.last_content_action = nil
    end
    if action == "sticky" then notify("sticky mode " .. (result.sticky and "on" or "off"))
    elseif action == "save" then notify("conversation saved")
    elseif action == "compact" then notify("conversation compacted; file context will be resent")
    elseif action == "new" then notify("started a new conversation")
    elseif action == "clear" then notify("cleared active working context") end
  end)
end

local function parse_quantity(value)
  local number, suffix = value:lower():match("^(%d+%.?%d*)([km]?)$")
  number = tonumber(number)
  if not number then return nil end
  if suffix == "k" then number = number * 1000 elseif suffix == "m" then number = number * 1000000 end
  return math.floor(number)
end

local function known_native_variant(expression)
  if expression:match("^claude%-opus%-4%-[678]%[1m%]$") then return true end
  if expression:match("^claude%-sonnet%-4%-6%[1m%]$") then return true end
  for _, item in ipairs(state.models) do
    if item.value == expression then return true end
  end
  return false
end

function M.parse_model_expression(expression, current)
  expression = vim.trim(expression)
  if expression == "" then return nil, "model expression cannot be empty" end
  local effort
  local prefix, suffix = expression:match("^(.*):([^:]*)$")
  if prefix and valid_efforts[suffix] then expression, effort = prefix, suffix end
  local explicit = expression:match("%[limit=([^%]]+)%]$")
  local limit
  if explicit then
    limit = parse_quantity(explicit)
    if not limit then return nil, "invalid context limit" end
    expression = expression:gsub("%[limit=[^%]]+%]$", "")
  else
    local groups = {}
    for value in expression:gmatch("%[([^%]]+)%]") do table.insert(groups, value) end
    if #groups >= 2 then
      local parsed = parse_quantity(groups[#groups])
      if parsed then
        limit = parsed
        expression = expression:sub(1, #expression - #groups[#groups] - 2)
      end
    elseif #groups == 1 and not known_native_variant(expression) then
      local parsed = parse_quantity(groups[1])
      if parsed then
        limit = parsed
        expression = expression:sub(1, #expression - #groups[1] - 2)
      end
    end
  end
  if expression == "" then return nil, "runtime model cannot be empty" end
  return {
    model = expression,
    effort = effort or current.effort,
    context_limit_tokens = limit or current.context_limit_tokens,
  }
end

local function configure_model(choice)
  bridge.call("configure", {
    model = choice.model,
    effort = choice.effort or vim.NIL,
    contextLimitTokens = choice.context_limit_tokens or vim.NIL,
  }, function(_, err)
    if err then notify(err, vim.log.levels.ERROR); return end
    state.opts.model = choice.model
    state.opts.effort = choice.effort
    state.opts.context_limit_tokens = choice.context_limit_tokens
    notify(("model %s%s"):format(choice.model, choice.effort and (":" .. choice.effort) or ""))
  end)
end

local function manual_model()
  ui.input("Claude model: ", state.opts.model .. (state.opts.context_limit_tokens and ("[" .. state.opts.context_limit_tokens .. "]") or "") .. (state.opts.effort and (":" .. state.opts.effort) or ""), function(value)
    if not value then return end
    local parsed, err = M.parse_model_expression(value, { effort = state.opts.effort, context_limit_tokens = state.opts.context_limit_tokens })
    if not parsed then notify(err, vim.log.levels.ERROR); return end
    configure_model(parsed)
  end)
end

local function choose_budget(model, effort)
  local items = { { label = "model default", value = nil } }
  for _, value in ipairs(context_presets) do table.insert(items, { label = (value / 1000) .. "k", value = value }) end
  ui.select(items, { prompt = "Context budget", format_item = function(item) return item.label end }, function(item)
    if item then configure_model({ model = model, effort = effort, context_limit_tokens = item.value }) end
  end)
end

local function choose_model()
  bridge.call("initialize", {}, function(info, err)
    if err then notify(err, vim.log.levels.ERROR); return end
    state.models = info.models or {}
    if #state.models == 0 then manual_model(); return end
    ui.select(state.models, {
      prompt = "Claude model",
      format_item = function(item) return item.displayName .. "  " .. (item.description or "") end,
    }, function(item)
      if not item then return end
      local levels = item.supportedEffortLevels or {}
      if not item.supportsEffort or #levels == 0 then choose_budget(item.value, nil); return end
      ui.select(levels, { prompt = "Reasoning effort" }, function(effort)
        if effort then choose_budget(item.value, effort) end
      end)
    end)
  end)
end

local function show_info()
  bridge.call("session", { action = "info" }, function(info, err)
    if err then notify(err, vim.log.levels.ERROR); return end
    local usage = info.usage or {}
    local cache = "unknown"
    if info.lastTurnAt then
      cache = math.max(0, math.floor(info.cacheTtlSeconds - (os.time() - info.lastTurnAt))) .. "s estimated"
    end
    local account = info.account or {}
    local cumulative = info.cumulativeUsage or {}
    local cumulative_text = table.concat({
      "input=" .. tostring(cumulative.input_tokens or cumulative.inputTokens or "unknown"),
      "cached=" .. tostring(cumulative.cache_read_input_tokens or cumulative.cacheReadInputTokens or "unknown"),
      "output=" .. tostring(cumulative.output_tokens or cumulative.outputTokens or "unknown"),
    }, ", ")
    ui.info(state.opts, "NvClaude session", {
      "Model: " .. tostring(info.model) .. (info.effort and (":" .. info.effort) or ""),
      "Local budget: " .. (info.contextLimitTokens and (info.contextLimitTokens .. " tokens") or "model default"),
      "Context occupancy: " .. (usage.totalTokens and (usage.totalTokens .. " / " .. tostring(usage.maxTokens)) or "unavailable"),
      "Cumulative usage: " .. cumulative_text,
      "Retention: " .. (info.saved and "saved" or "ephemeral") .. (info.sticky and ", sticky on" or ""),
      "Cache reuse window: " .. cache .. " (" .. tostring(info.cacheProvenance) .. ")",
      "Authentication: " .. tostring(account.subscriptionType or account.apiProvider or "unknown"),
      "Python / SDK / CLI: " .. tostring(info.pythonVersion) .. " / " .. tostring(info.sdkVersion) .. " / " .. tostring(info.cliVersion),
      "Budget policy: " .. tostring(info.budgetEnforcement),
      "Session: " .. tostring(info.logicalId),
    }, api.nvim_get_current_win())
  end)
end

local function list_sessions()
  bridge.call("session", { action = "list" }, function(items, err)
    if err then notify(err, vim.log.levels.ERROR); return end
    if #items == 0 then notify("no saved conversations"); return end
    ui.select(items, {
      prompt = "Saved Claude conversations",
      format_item = function(item)
        return os.date("%y:%m:%d:%H:%M:%S", item.created_at or 0) .. " - " .. (item.first_prompt ~= "" and item.first_prompt or "untitled") .. " [" .. item.logical_id:sub(1, 8) .. "]"
      end,
    }, function(item)
      if item then session("resume", { logicalId = item.logical_id }) end
    end)
  end)
end

local function cancel()
  if not state.active then notify("no active request"); return end
  local active = state.active
  active.cancelled = true
  finish_active(active)
  bridge.call("cancel", {}, function(_, err)
    if err then notify(err, vim.log.levels.ERROR) else notify("request cancelled") end
  end)
end

local function watermarks(mode)
  if mode and ({ allow = true, remove = true, replace = true })[mode] then
    state.opts.punctuation = mode
    notify("punctuation policy set to " .. mode)
  else
    notify("use: NvClaude watermarks allow|remove|replace", vim.log.levels.WARN)
  end
end

local function read_default_prompt()
  return table.concat(vim.fn.readfile(bridge.root() .. "/resources/system-prompt.txt"), "\n")
end

local function system_command(action)
  if state.active then notify("finish or cancel the active request first", vim.log.levels.WARN); return end
  if action == "default" then
    state.system_prompt = read_default_prompt()
    bridge.call("system_prompt", { prompt = state.system_prompt }, function(_, err)
      if err then notify(err, vim.log.levels.ERROR) else notify("restored the built-in system prompt") end
    end)
  elseif action == "modify" then
    state.system_prompt = state.system_prompt or read_default_prompt()
    ui.edit_system_prompt(state.opts, state.system_prompt, function(updated, done)
      bridge.call("system_prompt", { prompt = updated }, function(_, err)
        if err then notify(err, vim.log.levels.ERROR); done(false); return end
        state.system_prompt = updated
        context.invalidate()
        notify("system prompt updated for this Neovim session")
        done(true)
      end)
    end)
  else
    notify("use: NvClaude system modify|default", vim.log.levels.WARN)
  end
end

local function login()
  bridge.call("initialize", {}, function(info, err)
    if err then notify(err, vim.log.levels.ERROR); return end
    vim.cmd("tabnew")
    vim.fn.jobstart({ info.cliPath, "auth", "login" }, { term = true })
    vim.cmd.startinsert()
  end)
end

local function command(arguments)
  local args = vim.split(vim.trim(arguments), "%s+", { trimempty = true })
  local name = args[1] or "ask"
  if name == "ask" then
    if args[2] == "previous" then ask_previous() else ask_general() end
  elseif name == "replace" then replace()
  elseif name == "generate" then generate(false)
  elseif name == "cancel" then cancel()
  elseif name == "new" or name == "clear" or name == "save" or name == "compact" then session(name)
  elseif name == "sticky" then
    local value = args[2] == "on" and true or args[2] == "off" and false or nil
    session("sticky", { value = value })
  elseif name == "list" then list_sessions()
  elseif name == "info" then show_info()
  elseif name == "model" then choose_model()
  elseif name == "model-manual" then manual_model()
  elseif name == "watermarks" then watermarks(args[2])
  elseif name == "system" then system_command(args[2])
  elseif name == "login" then login()
  elseif name == "update" then
    bridge.update(function(_, err) if err then notify(err, vim.log.levels.ERROR) else notify("SDK environment updated") end end)
  else
    notify("unknown command: " .. name, vim.log.levels.ERROR)
  end
end

local function completion(arglead, cmdline)
  local top = { "ask", "replace", "generate", "cancel", "new", "clear", "save", "sticky", "compact", "list", "info", "model", "model-manual", "watermarks", "system", "login", "update" }
  local words = vim.split(cmdline, "%s+", { trimempty = true })
  local values = top
  if #words >= 2 then
    if words[2] == "sticky" then values = { "on", "off" }
    elseif words[2] == "watermarks" then values = { "allow", "remove", "replace" }
    elseif words[2] == "system" then values = { "modify", "default" }
    elseif words[2] == "ask" then values = { "previous" }
    else values = {} end
  end
  return vim.tbl_filter(function(value) return value:find("^" .. vim.pesc(arglead)) ~= nil end, values)
end

local action_handlers = {
  replace = replace,
  replace_short = replace,
  ask = ask,
  generate = function() generate(false) end,
  generate_insert = function() generate(true) end,
  model = choose_model,
  model_manual = manual_model,
  clear = function() session("clear") end,
  new = function() session("new") end,
  sticky = function() session("sticky") end,
  save = function() session("save") end,
  info = show_info,
  list = list_sessions,
}

local function remove_old_maps()
  for _, item in ipairs(state.installed_maps) do pcall(vim.keymap.del, item.mode, item.lhs) end
  state.installed_maps = {}
end

local function install_maps()
  remove_old_maps()
  if state.opts.keys == false then return end
  for name, spec in pairs(action_specs) do
    local lhs = state.opts.keys[name]
    if lhs and lhs ~= false then
      for _, mode in ipairs(spec.modes) do
        local existing = vim.fn.maparg(lhs, mode, false, true)
        local may_replace = state.opts._explicit_keys[name]
        if may_replace or not existing or vim.tbl_isempty(existing) then
          vim.keymap.set(mode, lhs, action_handlers[name], { silent = true, desc = spec.desc })
          table.insert(state.installed_maps, { mode = mode, lhs = lhs })
        end
      end
    end
  end
end

function M.setup(options)
  state.opts = config.resolve(options)
  bridge.setup(state.opts)
  api.nvim_create_user_command("NvClaude", function(command_opts) command(command_opts.args) end, {
    nargs = "*",
    complete = completion,
    force = true,
    desc = "Cursor-local Claude editing",
  })
  install_maps()
  bridge.on("request/partial", function(params)
    local active = state.active
    if not active or active.cancelled or active.operation ~= "ask" then return end
    active.streamed = active.streamed .. params.text
    ui.answer_append(state.opts, normalize(params.text))
  end)
  bridge.on("request/status", function(params)
    if state.active and not state.active.cancelled then notify(params.status) end
  end)
  state.setup = true
end

M._state = state
M._normalize = normalize

return M
