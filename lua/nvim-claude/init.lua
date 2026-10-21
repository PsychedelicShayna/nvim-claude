local config_module = require("nvim-claude.config")
local controller = require("nvim-claude.controller")
local util = require("nvim-claude.util")

local M = {}
local installed_mappings = {}

local actions = {
  ask = function(args) controller.ask(args[2] == "previous") end,
  replace = function() controller.replace() end,
  generate = function() controller.generate("n") end,
  cancel = function() controller.cancel() end,
  clear = function() controller.clear() end,
  new = function() controller.new() end,
  save = function() controller.save() end,
  compact = function() controller.compact() end,
  info = function() controller.info() end,
  list = function() controller.list() end,
  login = function() controller.login() end,
  sticky = function(args)
    local value
    if args[2] == "on" then value = true elseif args[2] == "off" then value = false end
    controller.sticky(value)
  end,
  model = function(args)
    if args[2] == "manual" then
      controller.model_manual(table.concat(args, " ", 3))
    else
      controller.model_picker()
    end
  end,
  watermarks = function(args) controller.watermarks(args[2]) end,
  system = function(args)
    if args[2] == "modify" then controller.system_modify()
    elseif args[2] == "default" then controller.system_default()
    else util.notify("system expects modify or default", vim.log.levels.ERROR) end
  end,
}

local completion = {
  [1] = { "ask", "replace", "generate", "cancel", "clear", "new", "save", "sticky", "compact", "info", "list", "model", "login", "watermarks", "system" },
  ask = { "previous" },
  sticky = { "on", "off" },
  model = { "manual" },
  watermarks = { "allow", "remove", "replace" },
  system = { "modify", "default" },
}

local function complete(_, command_line, _)
  local words = vim.split(command_line, "%s+", { trimempty = true })
  if #words <= 1 then return completion[1] end
  if #words == 2 and not command_line:match("%s$") then
    return vim.tbl_filter(function(item) return vim.startswith(item, words[2]) end, completion[1])
  end
  local candidates = completion[words[2]] or {}
  local prefix = command_line:match("(%S*)$") or ""
  return vim.tbl_filter(function(item) return vim.startswith(item, prefix) end, candidates)
end

local function run_command(options)
  local args = vim.split(options.args, "%s+", { trimempty = true })
  if #args == 0 then
    controller.ask(false)
    return
  end
  local action = actions[args[1]]
  if not action then
    util.notify("unknown command: " .. args[1], vim.log.levels.ERROR)
    return
  end
  action(args)
end

local function remove_mappings()
  for _, mapping in ipairs(installed_mappings) do
    pcall(vim.keymap.del, mapping.mode, mapping.lhs)
  end
  installed_mappings = {}
end

local function map(mode, lhs, callback, description, explicit)
  if lhs == false or lhs == nil then return end
  local modes = type(mode) == "table" and mode or { mode }
  for _, one_mode in ipairs(modes) do
    local existing = vim.fn.maparg(lhs, one_mode)
    if existing == "" or explicit then
      vim.keymap.set(one_mode, lhs, callback, { silent = true, desc = description })
      table.insert(installed_mappings, { mode = one_mode, lhs = lhs })
    end
  end
end

local function configure_mappings(config, opts)
  remove_mappings()
  if config.keys == false then return end
  local supplied = type(opts.keys) == "table" and opts.keys or {}
  local function explicit(name) return supplied[name] ~= nil end
  map({ "n", "x" }, config.keys.replace, controller.replace, "Claude: replace selection", explicit("replace"))
  map({ "n", "x" }, config.keys.replace_short, controller.replace, "Claude: replace selection (short)", explicit("replace_short"))
  map({ "n", "x" }, config.keys.ask, function() controller.ask(false) end, "Claude: ask", explicit("ask"))
  map("n", config.keys.generate, function() controller.generate("n") end, "Claude: generate", explicit("generate"))
  map("i", config.keys.generate_insert, function() controller.generate("i") end, "Claude: generate", explicit("generate_insert"))
  map("n", config.keys.model, controller.model_picker, "Claude: choose model", explicit("model"))
  map("n", config.keys.model_manual, function() controller.model_manual() end, "Claude: enter model", explicit("model_manual"))
  map("n", config.keys.clear, controller.clear, "Claude: clear conversation", explicit("clear"))
  map("n", config.keys.new, controller.new, "Claude: new conversation", explicit("new"))
  map("n", config.keys.sticky, function() controller.sticky(nil) end, "Claude: toggle sticky mode", explicit("sticky"))
  map("n", config.keys.save, controller.save, "Claude: save conversation", explicit("save"))
  map("n", config.keys.info, controller.info, "Claude: show info", explicit("info"))
  map("n", config.keys.list, controller.list, "Claude: list conversations", explicit("list"))
end

function M.setup(opts)
  opts = opts or {}
  local config = config_module.resolve(opts)
  controller.setup(config)
  configure_mappings(config, opts)
  vim.api.nvim_create_user_command("NvClaude", run_command, {
    nargs = "*",
    complete = complete,
    desc = "Cursor-local Claude editing",
    force = true,
  })
  local group = vim.api.nvim_create_augroup("NvClaudeLifecycle", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = controller.shutdown })
  return config
end

return M
