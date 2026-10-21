local M = {}

M.default_keys = {
  replace = "<leader>cc",
  replace_short = "<leader>c",
  ask = "<leader>ca",
  generate = "<leader>ci",
  generate_insert = false,
  model = "<leader>cm",
  model_manual = "<leader>cM",
  clear = "<leader>cC",
  new = "<leader>cn",
  sticky = "<leader>cS",
  save = "<leader>cs",
  info = "<leader>cx",
  list = "<leader>cl",
}

M.defaults = {
  python = nil,
  model = "claude-haiku-5-5",
  effort = "low",
  context_limit_tokens = 100000,
  cache_ttl_seconds = 3600,
  runtime_overhead_tokens = 16384,
  output_reserve_tokens = 8192,
  punctuation = "allow",
  punctuation_map = {
    ["—"] = "-",
    ["–"] = "-",
    ["‘"] = "'",
    ["’"] = "'",
    ["“"] = '"',
    ["”"] = '"',
    ["…"] = "...",
    [" "] = " ",
  },
  keys = M.default_keys,
}

M.context_presets = {
  50000, 90000, 100000, 124000, 150000, 164000, 200000, 224000,
  256000, 258000, 274000, 278000, 300000, 374000, 378000, 384000,
  412000, 456000, 500000, 512000, 600000, 650000, 700000, 750000,
  800000, 850000, 900000, 950000, 980000,
}

M.efforts = { low = true, medium = true, high = true, xhigh = true, max = true }

local function copy(value)
  return vim.deepcopy(value)
end

function M.resolve(opts)
  opts = opts or {}
  local resolved = vim.tbl_deep_extend("force", copy(M.defaults), opts)
  if opts.keys == false then
    resolved.keys = false
  else
    resolved.keys = copy(M.default_keys)
    if type(opts.keys) == "table" then
      for name, value in pairs(opts.keys) do
        resolved.keys[name] = value
      end
    end
  end
  return resolved
end

local function parse_amount(value)
  local number, suffix = value:lower():match("^(%d+%.?%d*)([km]?)$")
  number = tonumber(number)
  if not number then
    return nil
  end
  if suffix == "k" then
    number = number * 1000
  elseif suffix == "m" then
    number = number * 1000000
  end
  if number ~= math.floor(number) or number < 1 then
    return nil
  end
  return number
end

function M.parse_model_expression(expression, current, runtime_models)
  local value = vim.trim(expression or "")
  if value == "" then
    return nil, "Model expression is empty"
  end

  local effort
  local candidate_model, suffix = value:match("^(.*):([^:]*)$")
  if candidate_model and M.efforts[suffix] then
    value, effort = candidate_model, suffix
  end

  local limit
  local explicit = value:match("%[limit=([^%]]+)%]$")
  if explicit then
    limit = parse_amount(explicit)
    if not limit then
      return nil, "Invalid context limit: " .. explicit
    end
    value = value:gsub("%[limit=[^%]]+%]$", "")
  else
    local groups = {}
    for group in value:gmatch("%[([^%]]+)%]") do
      table.insert(groups, group)
    end
    local last = groups[#groups]
    if last and parse_amount(last) then
      local full_is_runtime_model = runtime_models and runtime_models[value]
      local native_one_million = last:lower() == "1m" and value:match("^claude%-opus%-4%-6%[1m%]$")
      if #groups >= 2 or (not full_is_runtime_model and not native_one_million) then
        limit = parse_amount(last)
        value = value:sub(1, #value - #last - 2)
      end
    end
  end

  if value == "" then
    return nil, "Runtime model is empty"
  end
  return {
    model = value,
    effort = effort or current.effort,
    context_limit_tokens = limit or current.context_limit_tokens,
  }
end

function M.format_model(config)
  local budget = config.context_limit_tokens and ("[%dk]"):format(config.context_limit_tokens / 1000) or "[default]"
  local effort = config.effort and (":" .. config.effort) or ""
  return config.model .. budget .. effort
end

return M
