local config = require("nvim-claude.config")
local context = require("nvim-claude.context")
local model = require("nvim-claude.model")
local punctuation = require("nvim-claude.punctuation")
local rpc = require("nvim-claude.rpc")
local target = require("nvim-claude.target")
local ui = require("nvim-claude.ui")

local M = {}
local api = vim.api
local uv = vim.uv or vim.loop

local command_names = {
  "ask",
  "replace",
  "generate",
  "model",
  "new",
  "clear",
  "save",
  "sticky",
  "list",
  "compact",
  "cancel",
  "info",
  "watermarks",
  "system",
  "login",
  "update",
}

local state = {
  setup = false,
  options = nil,
  explicit_keys = nil,
  mappings = {},
  initialized = false,
  initializing = false,
  initialize_waiters = {},
  initialization = nil,
  current = nil,
  epoch = 0,
  serial = 0,
  model = nil,
  effort = nil,
  context_limit_tokens = nil,
  punctuation = "allow",
  selected_ask = nil,
  last_content_action = nil,
  system_prompt = nil,
}

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "nvim-claude" })
end

local function error_text(value)
  if type(value) == "table" then
    return value.message or value.error or vim.inspect(value)
  end
  return tostring(value)
end

local function plugin_root()
  local source = debug.getinfo(1, "S").source:gsub("^@", "")
  local dirname = vim.fs and vim.fs.dirname or function(path)
    return path:match("^(.*)[/\\][^/\\]+$")
  end
  return dirname(dirname(dirname(source)))
end

local function default_system_prompt()
  local path = plugin_root() .. "/resources/system_prompt.txt"
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil, "Could not read the packaged system prompt at " .. path
  end
  return table.concat(lines, "\n") .. "\n"
end

local function next_request_id()
  state.serial = state.serial + 1
  return string.format("nvim-%d-%d-%d", vim.fn.getpid(), uv.hrtime(), state.serial)
end

local function current_model()
  return {
    model = state.model,
    effort = state.effort,
    context_limit_tokens = state.context_limit_tokens,
  }
end

local function invalidate_selected_ask()
  if state.selected_ask and state.selected_ask.target then
    target.release(state.selected_ask.target)
  end
  state.selected_ask = nil
end

local function set_content_action(action)
  if action ~= "ask_selected" then
    invalidate_selected_ask()
  end
  state.last_content_action = action
end

local function ensure_backend(callback)
  local status = rpc.status()
  if state.initialized and status.running then
    callback(nil, state.initialization)
    return
  end
  if state.initialized and not status.running then
    state.initialized = false
    state.initialization = nil
  end
  state.initialize_waiters[#state.initialize_waiters + 1] = callback
  if state.initializing then
    return
  end
  state.initializing = true
  rpc.initialize({ state_dir = state.options.state_dir }, {
    on_progress = function(progress)
      if state.current and state.current.output then
        state.current.output:set_status(progress.message or progress.phase or "setting up")
      end
    end,
    on_result = function(result)
      state.initializing = false
      state.initialized = true
      state.initialization = result
      local waiters = state.initialize_waiters
      state.initialize_waiters = {}
      for _, waiter in ipairs(waiters) do
        waiter(nil, result)
      end
    end,
    on_error = function(err)
      state.initializing = false
      state.initialized = false
      local message = error_text(err)
      local waiters = state.initialize_waiters
      state.initialize_waiters = {}
      for _, waiter in ipairs(waiters) do
        waiter(message)
      end
    end,
  })
end

local function release_request_target(request, keep)
  if request and request.target and not keep then
    target.release(request.target)
  end
end

local function finish_with_error(request, message, uncertain)
  if state.current ~= request then
    return
  end
  if request.prepared then
    context.rejected(request.prepared, uncertain ~= false)
  end
  request.output:set_status("error")
  if request.output:text() ~= "" then
    request.output:append("\n\n")
  end
  request.output:append(message)
  release_request_target(request, false)
  state.current = nil
end

local function apply_edit_result(request, raw)
  local decoded, decode_error = target.decode_result(request.target, raw)
  if not decoded then
    request.output:set_status("invalid edit result")
    request.output:set_text(raw .. "\n\n" .. decode_error)
    release_request_target(request, false)
    return
  end
  if decoded.status == "needs_input" then
    request.output:set_status("needs input")
    request.output:set_text(punctuation.apply(decoded.message, state.punctuation))
    release_request_target(request, false)
    return
  end
  for _, replacement in ipairs(decoded.replacements) do
    replacement.text = punctuation.apply(replacement.text, state.punctuation)
  end
  local outcome = target.apply(request.target, decoded)
  if not outcome.applied then
    request.output:set_status("not applied")
    request.output:set_text((outcome.text or raw) .. "\n\n" .. (outcome.reason or "The target is no longer valid."))
    release_request_target(request, false)
    return
  end
  if request.operation == "replace" then
    set_content_action("replace")
  else
    set_content_action("generate")
    target.release(request.target)
  end
  request.output:dispose()
  notify(outcome.changed and "Claude edit applied" or "Claude completed with no buffer change")
end

local function finish_result(request, event)
  if state.current ~= request then
    return
  end
  if request.prepared then
    local accepted, accept_error = context.accept(request.prepared)
    if not accepted then
      context.invalidate(request.prepared.pending and request.prepared.pending.bufnr or nil)
      finish_with_error(request, "The accepted buffer baseline could not be recorded: " .. accept_error, true)
      return
    end
  end
  local raw = event.raw or request.raw or ""
  if request.operation == "ask" then
    request.output:set_status("complete")
    if request.target then
      if state.selected_ask and state.selected_ask.target ~= request.target then
        target.release(state.selected_ask.target)
      end
      state.selected_ask = { bufnr = request.target.bufnr, target = request.target }
      state.last_content_action = "ask_selected"
    else
      set_content_action("ask_general")
    end
  else
    apply_edit_result(request, raw)
  end
  state.current = nil
end

local function handle_turn_event(request, event)
  if state.current ~= request or event.request_id ~= request.id or tonumber(event.epoch) ~= request.epoch then
    return
  end
  if event.type == "status" then
    request.output:set_status(event.status or "running")
  elseif event.type == "delta" then
    request.raw = request.raw .. (event.text or "")
    if request.operation == "ask" then
      request.output:append(punctuation.apply(event.text or "", state.punctuation))
    else
      request.output:append(event.text or "")
    end
  elseif event.type == "compacted" then
    context.invalidate()
    request.output:set_status("compacted")
  elseif event.type == "result" then
    finish_result(request, event)
  elseif event.type == "error" then
    finish_with_error(request, event.message or "The Claude request failed.", true)
  end
end

local function context_limit_bytes()
  if state.context_limit_tokens == false or state.context_limit_tokens == nil then
    return nil
  end
  return math.max(2048, state.context_limit_tokens - 16000)
end

local function prepare_envelope(operation, instruction, edit_target)
  local envelope = {
    operation = operation,
    instruction = instruction,
    coordinates = "zero-based UTF-8 bytes; end-exclusive",
  }
  if not edit_target then
    return envelope, nil
  end
  local prepared, prepare_error = context.prepare(edit_target.bufnr, {
    target = edit_target,
    max_bytes = context_limit_bytes(),
  })
  if not prepared then
    return nil, prepare_error
  end
  envelope.document = prepared.document
  envelope.context = prepared.context
  envelope.targets = prepared.targets
  return envelope, prepared
end

local function dispatch_turn(operation, instruction, edit_target, origin_win)
  if state.current then
    return false, "A Claude request is already running. Cancel it or wait; this draft was kept."
  end
  if not instruction:find("%S") then
    return false, "Enter an instruction before submitting."
  end
  local envelope, prepared_or_error = prepare_envelope(operation, instruction, edit_target)
  if not envelope then
    return false, prepared_or_error
  end
  local prepared = prepared_or_error
  if operation ~= "ask" then
    set_content_action(operation)
  elseif not edit_target then
    set_content_action("ask_general")
  end
  local continued = state.initialization
    and state.initialization.conversation
    and state.initialization.conversation.session_id
  local output_factory = operation == "ask" and ui.answer or ui.result
  local output = output_factory({
    origin_win = origin_win,
    status = continued and "continued" or "new",
    text = "",
  })
  local request = {
    id = next_request_id(),
    epoch = state.epoch,
    operation = operation,
    target = edit_target,
    prepared = prepared,
    output = output,
    raw = "",
  }
  state.current = request
  ensure_backend(function(start_error)
    if state.current ~= request then
      return
    end
    if start_error then
      finish_with_error(request, start_error, true)
      return
    end
    rpc.call("turn", {
      request_id = request.id,
      epoch = request.epoch,
      operation = operation,
      envelope = envelope,
      model = state.model,
      effort = state.effort,
      context_limit_tokens = state.context_limit_tokens,
      system_prompt = state.system_prompt,
    }, {
      on_progress = function(progress)
        handle_turn_event(request, progress)
      end,
      on_event = function(event)
        handle_turn_event(request, event)
      end,
      on_error = function(err)
        if state.current == request then
          finish_with_error(request, error_text(err), true)
        end
      end,
    })
  end)
  return true
end

local function visual_mode()
  local mode = vim.fn.mode(1):sub(1, 1)
  return mode == "v" or mode == "V" or mode == "\22"
end

local function capture_for_operation(operation, opts)
  opts = opts or {}
  local origin_win = api.nvim_get_current_win()
  local bufnr = api.nvim_get_current_buf()
  if operation == "generate" then
    return target.capture_insert({
      bufnr = bufnr,
      winid = origin_win,
      mode = opts.insert_mode and "i" or "n",
      operation = "generate",
    })
  end
  if opts.visual or visual_mode() then
    return target.capture_visual({ bufnr = bufnr, operation = operation })
  end
  if operation == "replace" then
    return target.remembered(bufnr)
  end
  if operation == "ask" and opts.previous then
    if not state.selected_ask or state.selected_ask.bufnr ~= bufnr then
      return nil, "There is no selected-ask target in this buffer."
    end
    local valid, valid_error = target.validate(state.selected_ask.target, false)
    if not valid then
      invalidate_selected_ask()
      return nil, valid_error
    end
    return state.selected_ask.target
  end
  if operation == "ask"
    and opts.mapping
    and state.last_content_action == "ask_selected"
    and state.selected_ask
    and state.selected_ask.bufnr == bufnr
  then
    local valid = target.validate(state.selected_ask.target, false)
    if valid then
      return state.selected_ask.target
    end
    invalidate_selected_ask()
  end
  return nil
end

function M.open(operation, opts)
  opts = opts or {}
  local origin_win = api.nvim_get_current_win()
  local edit_target, capture_error = capture_for_operation(operation, opts)
  local target_required = operation ~= "ask" or opts.visual or opts.previous
  if target_required and not edit_target then
    notify(capture_error or "A valid target is required.", vim.log.levels.ERROR)
    return
  end
  ui.prompt({
    origin_win = origin_win,
    operation = operation,
    model = state.model,
    target = edit_target,
    status = state.current and "busy" or nil,
    on_submit = function(instruction)
      return dispatch_turn(operation, instruction, edit_target, origin_win)
    end,
    on_cancel = function()
      if edit_target and edit_target ~= (state.selected_ask and state.selected_ask.target) then
        local remembered = operation == "replace" and target.remembered(edit_target.bufnr)
        if remembered ~= edit_target then
          target.release(edit_target)
        end
      end
    end,
  })
end

function M.cancel()
  local request = state.current
  if not request then
    notify("No Claude request is running")
    return
  end
  state.epoch = state.epoch + 1
  state.current = nil
  request.output:set_status("cancelled")
  if request.output:text() == "" then
    request.output:set_text("Request cancelled; no edit was applied.")
  end
  if request.prepared then
    context.rejected(request.prepared, true)
  end
  release_request_target(request, false)
  rpc.cancel(request.id, request.epoch, {
    on_error = function(err)
      notify("Cancellation failed: " .. error_text(err), vim.log.levels.ERROR)
    end,
  })
end

local function transition(method, params, on_result)
  local function run()
    ensure_backend(function(start_error)
      if start_error then
        notify(start_error, vim.log.levels.ERROR)
        return
      end
      rpc.call(method, params or {}, {
        on_result = function(result)
          state.epoch = state.epoch + 1
          context.reset()
          invalidate_selected_ask()
          state.last_content_action = nil
          if state.initialization and result.conversation then
            state.initialization.conversation = result.conversation
          end
          if on_result then
            on_result(result)
          end
        end,
        on_error = function(err)
          notify(error_text(err), vim.log.levels.ERROR)
        end,
      })
    end)
  end
  if state.current then
    local request = state.current
    state.epoch = state.epoch + 1
    state.current = nil
    request.output:set_status("cancelled")
    rpc.cancel(request.id, request.epoch, {
      on_result = run,
      on_error = function(err)
        notify(error_text(err), vim.log.levels.ERROR)
      end,
    })
  else
    run()
  end
end

local function format_limit(value)
  if value == false or value == nil then
    return "model default"
  end
  if value % 1000000 == 0 then
    return string.format("%dm", value / 1000000)
  end
  if value % 1000 == 0 then
    return string.format("%dk", value / 1000)
  end
  return tostring(value)
end

local function choose_budget(on_select)
  local items = { { label = "model default", value = false } }
  for _, value in ipairs(model.context_presets) do
    items[#items + 1] = { label = format_limit(value), value = value }
  end
  ui.picker({
    title = "Claude context budget",
    items = items,
    on_select = function(item)
      on_select(item.value)
    end,
  })
end


local function choose_model()
  ensure_backend(function(start_error)
    if start_error then
      notify(start_error, vim.log.levels.ERROR)
      return
    end
    rpc.call("models", current_model(), {
      on_result = function(result)
        if type(result.models) ~= "table" or #result.models == 0 then
          notify("The runtime did not announce a model catalogue. Use :NvClaude model <slug>.", vim.log.levels.WARN)
          return
        end
        ui.picker({
          title = "Claude model",
          items = result.models,
          format_item = function(item)
            return item.display_name or item.displayName or item.name or item.id
          end,
          on_select = function(item)
            local selected = item.id or item.value or item.model or item.name
            local efforts = model.runtime_efforts(item)
            local function finish(selected_effort)
              choose_budget(function(limit)
                state.model = selected
                state.effort = selected_effort
                state.context_limit_tokens = limit
                notify("Claude model: " .. selected .. ", " .. (selected_effort or "effort unknown") .. ", " .. format_limit(limit))
              end)
            end
            if efforts then
              ui.picker({
                title = "Claude effort",
                items = efforts,
                on_select = finish,
              })
            else
              finish(nil)
            end
          end,
        })
      end,
      on_error = function(err)
        notify(error_text(err), vim.log.levels.ERROR)
      end,
    })
  end)
end

local function set_model_expression(expression)
  local parsed, parse_error = model.parse(expression, current_model())
  if not parsed then
    notify(parse_error, vim.log.levels.ERROR)
    return
  end
  state.model = parsed.model
  state.effort = parsed.effort
  state.context_limit_tokens = parsed.context_limit_tokens
  notify("Claude model: " .. state.model .. ", " .. (state.effort or "effort unknown") .. ", " .. format_limit(state.context_limit_tokens))
end

local function manual_model()
  vim.ui.input({ prompt = "Claude model expression: ", default = state.model }, function(value)
    if value and value:find("%S") then
      set_model_expression(value)
    end
  end)
end

local function show_info()
  ensure_backend(function(start_error)
    if start_error then
      notify(start_error, vim.log.levels.ERROR)
      return
    end
    rpc.call("session/info", {}, {
      on_result = function(result)
        local conversation = result.conversation or {}
        local runtime = result.runtime or {}
        local usage = result.context_usage or {}
        local cache = result.cache or {}
        local budget = result.budget or {}
        ui.info({
          lines = {
            "Model: " .. tostring(conversation.model or state.model),
            "Effort: " .. tostring(conversation.effort or state.effort or "unknown"),
            "Local budget: " .. format_limit(conversation.context_limit_tokens or state.context_limit_tokens),
            "Budget enforcement: " .. tostring(budget.enforcement or "unknown"),
            "Native hard ceiling verified: " .. tostring(budget.verified_native_hard_ceiling == true),
            "Context occupancy: " .. tostring(usage.totalTokens or "unknown") .. " / " .. tostring(usage.maxTokens or "unknown"),
            "Cumulative usage: " .. vim.inspect(result.cumulative_usage or {}),
            "Retention: " .. (conversation.saved and "saved" or "ephemeral") .. (result.sticky and ", sticky on" or ", sticky off"),
            "Cache estimate: " .. tostring(cache.ttl_seconds or "unknown") .. " seconds",
            "Cache provenance: " .. tostring(cache.provenance or "unknown"),
            "Resolved model: " .. tostring(runtime.resolved_model or "unknown"),
            "Python: " .. tostring(runtime.python or "unknown"),
            "Claude Agent SDK: " .. tostring(runtime.sdk or "unknown"),
            "Bundled Claude CLI: " .. tostring(runtime.cli or "unknown"),
            "No-tools check: " .. vim.inspect(result.no_tools or {}),
          },
        })
      end,
      on_error = function(err)
        notify(error_text(err), vim.log.levels.ERROR)
      end,
    })
  end)
end

local function list_conversations()
  ensure_backend(function(start_error)
    if start_error then
      notify(start_error, vim.log.levels.ERROR)
      return
    end
    rpc.call("session/list", {}, {
      on_result = function(result)
        local conversations = result.conversations or {}
        if #conversations == 0 then
          notify("No saved Claude conversations")
          return
        end
        ui.picker({
          title = "Saved Claude conversations",
          items = conversations,
          format_item = function(item)
            local timestamp = os.date("%y:%m:%d:%H:%M:%S", tonumber(item.created_at) or 0)
            local title = item.first_prompt ~= "" and item.first_prompt or "(untitled)"
            return timestamp .. " - " .. title .. " [" .. tostring(item.id):sub(1, 8) .. "]"
          end,
          on_select = function(item)
            transition("session/resume", { id = item.id }, function()
              notify("Resumed Claude conversation " .. tostring(item.id):sub(1, 8))
            end)
          end,
        })
      end,
      on_error = function(err)
        notify(error_text(err), vim.log.levels.ERROR)
      end,
    })
  end)
end

local function edit_system_prompt()
  local text = state.system_prompt
  if not text then
    local read_error
    text, read_error = default_system_prompt()
    if not text then
      notify(read_error, vim.log.levels.ERROR)
      return
    end
  end
  ui.system_prompt({
    text = text,
    start_insert = false,
    on_save = function(value)
      if not value:find("%S") then
        return false, "The system prompt cannot be empty."
      end
      state.system_prompt = value
      ensure_backend(function(start_error)
        if start_error then
          notify(start_error, vim.log.levels.ERROR)
          return
        end
        rpc.call("system/set", { prompt = value }, {
          on_result = function()
            notify("Claude system prompt updated for this Neovim session")
          end,
          on_error = function(err)
            notify(error_text(err), vim.log.levels.ERROR)
          end,
        })
      end)
      return true
    end,
  })
end

local function reset_system_prompt()
  local value, read_error = default_system_prompt()
  if not value then
    notify(read_error, vim.log.levels.ERROR)
    return
  end
  state.system_prompt = nil
  if state.initialized then
    rpc.call("system/set", { prompt = value }, {
      on_result = function()
        notify("Claude system prompt restored")
      end,
      on_error = function(err)
        notify(error_text(err), vim.log.levels.ERROR)
      end,
    })
  else
    notify("Claude system prompt restored")
  end
end

local function login()
  ensure_backend(function(start_error)
    if start_error then
      notify(start_error, vim.log.levels.ERROR)
      return
    end
    rpc.call("login", {}, {
      on_result = function(result)
        if type(result.argv) ~= "table" then
          notify(result.message or "The bundled CLI did not provide a login command.", vim.log.levels.ERROR)
          return
        end
        vim.cmd("botright new")
        vim.fn.termopen(result.argv)
        vim.cmd("startinsert")
      end,
      on_error = function(err)
        notify(error_text(err), vim.log.levels.ERROR)
      end,
    })
  end)
end

local function update_environment()
  if state.current then
    notify("Cancel the active request before updating the SDK environment.", vim.log.levels.ERROR)
    return
  end
  rpc.stop(function()
    local removed = vim.fn.delete(state.options.venv_dir, "rf")
    state.initialized = false
    state.initialization = nil
    if removed ~= 0 then
      notify("Could not remove the plugin environment at " .. state.options.venv_dir, vim.log.levels.ERROR)
      return
    end
    notify("Plugin environment removed. The next backend action will install the latest Claude Agent SDK.")
  end)
end

local function handle_command(opts)
  local args = vim.split(opts.args or "", "%s+", { trimempty = true })
  local command = table.remove(args, 1) or "ask"
  if command == "ask" then
    M.open("ask", { previous = args[1] == "previous" })
  elseif command == "replace" then
    M.open("replace")
  elseif command == "generate" then
    M.open("generate")
  elseif command == "model" then
    if #args == 0 then
      choose_model()
    elseif args[1] == "manual" then
      manual_model()
    else
      set_model_expression(table.concat(args, " "))
    end
  elseif command == "new" or command == "clear" then
    transition("session/" .. command, {}, function()
      notify(command == "new" and "Started a new Claude conversation" or "Cleared active Claude context")
    end)
  elseif command == "save" then
    ensure_backend(function(start_error)
      if start_error then
        notify(start_error, vim.log.levels.ERROR)
        return
      end
      rpc.call("session/save", {}, {
        on_result = function(result)
          if state.initialization then
            state.initialization.conversation = result.conversation
          end
          notify("Claude conversation saved")
        end,
        on_error = function(err)
          notify(error_text(err), vim.log.levels.ERROR)
        end,
      })
    end)
  elseif command == "sticky" then
    local enabled
    if args[1] == "on" then
      enabled = true
    elseif args[1] == "off" then
      enabled = false
    elseif args[1] ~= nil then
      notify("Usage: :NvClaude sticky [on|off]", vim.log.levels.ERROR)
      return
    end
    ensure_backend(function(start_error)
      if start_error then
        notify(start_error, vim.log.levels.ERROR)
        return
      end
      rpc.call("session/sticky", { enabled = enabled }, {
        on_result = function(result)
          notify("Claude sticky mode " .. (result.sticky and "on" or "off"))
        end,
        on_error = function(err)
          notify(error_text(err), vim.log.levels.ERROR)
        end,
      })
    end)
  elseif command == "list" then
    list_conversations()
  elseif command == "compact" then
    transition("session/compact", {}, function()
      notify("Claude conversation compacted; file baselines were reset")
    end)
  elseif command == "cancel" then
    M.cancel()
  elseif command == "info" then
    show_info()
  elseif command == "watermarks" then
    local policy = args[1]
    if not punctuation.is_valid(policy) then
      notify("Usage: :NvClaude watermarks allow|remove|replace", vim.log.levels.ERROR)
      return
    end
    state.punctuation = policy
    notify("Claude punctuation normalization: " .. policy)
  elseif command == "system" then
    if args[1] == "modify" then
      edit_system_prompt()
    elseif args[1] == "default" then
      reset_system_prompt()
    else
      notify("Usage: :NvClaude system modify|default", vim.log.levels.ERROR)
    end
  elseif command == "login" then
    login()
  elseif command == "update" then
    update_environment()
  else
    notify("Unknown NvClaude command: " .. command, vim.log.levels.ERROR)
  end
end

local function complete(_, command_line, _)
  local words = vim.split(command_line, "%s+", { trimempty = true })
  if #words <= 1 then
    return command_names
  end
  if #words == 2 and not command_line:match("%s$") then
    local lead = words[2]
    return vim.tbl_filter(function(value)
      return value:sub(1, #lead) == lead
    end, command_names)
  end
  if words[2] == "ask" then
    return { "previous" }
  elseif words[2] == "sticky" then
    return { "on", "off" }
  elseif words[2] == "watermarks" then
    return { "allow", "remove", "replace" }
  elseif words[2] == "system" then
    return { "modify", "default" }
  elseif words[2] == "model" then
    return { "manual" }
  end
  return {}
end

local action_specs = {
  replace = { modes = { "n", "x" }, description = "Claude replace target", callback = function()
    M.open("replace", { visual = visual_mode() })
  end },
  replace_short = { modes = { "n", "x" }, description = "Claude replace target", callback = function()
    M.open("replace", { visual = visual_mode() })
  end },
  ask = { modes = { "n", "x" }, description = "Ask Claude", callback = function()
    M.open("ask", { visual = visual_mode(), mapping = true })
  end },
  generate = { modes = { "n" }, description = "Claude generate at cursor", callback = function()
    M.open("generate")
  end },
  generate_insert = { modes = { "i" }, description = "Claude generate at insertion point", callback = function()
    M.open("generate", { insert_mode = true })
  end },
  model = { modes = { "n" }, description = "Choose Claude model", callback = choose_model },
  model_manual = { modes = { "n" }, description = "Enter Claude model", callback = manual_model },
  clear = { modes = { "n" }, description = "Clear Claude context", callback = function()
    handle_command({ args = "clear" })
  end },
  new = { modes = { "n" }, description = "New Claude conversation", callback = function()
    handle_command({ args = "new" })
  end },
  sticky = { modes = { "n" }, description = "Toggle Claude sticky mode", callback = function()
    handle_command({ args = "sticky" })
  end },
  save = { modes = { "n" }, description = "Save Claude conversation", callback = function()
    handle_command({ args = "save" })
  end },
  info = { modes = { "n" }, description = "Show Claude context info", callback = show_info },
  list = { modes = { "n" }, description = "List Claude conversations", callback = list_conversations },
}

local function clear_mappings()
  for _, mapping in ipairs(state.mappings) do
    pcall(vim.keymap.del, mapping.mode, mapping.lhs)
  end
  state.mappings = {}
end

local function install_mappings(opts)
  clear_mappings()
  if state.options.keys == false then
    return
  end
  local explicit = opts and opts.keys
  for name, spec in pairs(action_specs) do
    local lhs = state.options.keys[name]
    if type(lhs) == "string" and lhs ~= "" then
      local force = type(explicit) == "table" and explicit[name] ~= nil
      for _, mode_name in ipairs(spec.modes) do
        if force or vim.fn.maparg(lhs, mode_name) == "" then
          vim.keymap.set(mode_name, lhs, spec.callback, {
            silent = true,
            desc = spec.description,
          })
          state.mappings[#state.mappings + 1] = { mode = mode_name, lhs = lhs }
        end
      end
    end
  end
end

function M.setup(opts)
  opts = opts or {}
  state.options = config.setup(opts)
  state.explicit_keys = opts.keys
  state.model = state.options.model
  state.effort = state.options.effort
  state.context_limit_tokens = state.options.context_limit_tokens
  state.punctuation = state.options.punctuation
  if not punctuation.is_valid(state.punctuation) then
    error("nvim-claude punctuation must be allow, remove, or replace")
  end

  api.nvim_create_user_command("NvClaude", handle_command, {
    nargs = "*",
    complete = complete,
    desc = "Cursor-local Claude editing",
    force = true,
  })
  install_mappings(opts)

  local group = api.nvim_create_augroup("NvimClaude", { clear = true })
  api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(event)
      context.drop(event.buf)
      if state.selected_ask and state.selected_ask.bufnr == event.buf then
        invalidate_selected_ask()
      end
    end,
  })
  api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    once = true,
    callback = function()
      rpc.stop()
    end,
  })
  state.setup = true
  return M
end

M.command = handle_command
M.state = function()
  return vim.deepcopy({
    setup = state.setup,
    initialized = state.initialized,
    busy = state.current ~= nil,
    epoch = state.epoch,
    model = state.model,
    effort = state.effort,
    context_limit_tokens = state.context_limit_tokens,
    punctuation = state.punctuation,
    backend = rpc.status(),
  })
end

return M
