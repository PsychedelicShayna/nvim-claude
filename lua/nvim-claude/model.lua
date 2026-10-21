local M = {}

M.efforts = { "low", "medium", "high", "xhigh", "max" }
M.context_presets = {
  50000,
  90000,
  100000,
  124000,
  150000,
  164000,
  200000,
  224000,
  256000,
  258000,
  274000,
  278000,
  300000,
  374000,
  378000,
  384000,
  412000,
  456000,
  500000,
  512000,
  600000,
  650000,
  700000,
  750000,
  800000,
  850000,
  900000,
  950000,
  980000,
}

local known_effort = {}
for _, effort in ipairs(M.efforts) do
  known_effort[effort] = true
end

local function trim(value)
  return value:match("^%s*(.-)%s*$")
end

local function parse_budget(value)
  local token = trim(value)
  local suffix = token:sub(-1):lower()
  local multiplier = 1
  if suffix == "k" then
    multiplier = 1000
    token = token:sub(1, -2)
  elseif suffix == "m" then
    multiplier = 1000000
    token = token:sub(1, -2)
  end

  if not token:match("^%d+$") and not token:match("^%d+%.%d+$") then
    return nil, "context limit must be a positive number with an optional k or m suffix"
  end
  local amount = tonumber(token) * multiplier
  if amount <= 0 or amount ~= math.floor(amount) then
    return nil, "context limit must resolve to a positive whole number of tokens"
  end
  return amount
end

local function table_contains_variant(variants, base, token, candidate)
  if type(variants) ~= "table" then
    return false
  end
  if variants[candidate] == true then
    return true
  end

  local function matches(value)
    if type(value) == "string" then
      return value == candidate or value == token
    end
    if type(value) == "table" then
      local id = value.id or value.model or value.model_id or value.slug or value.selector
      return id == candidate or id == token
    end
    return false
  end

  local per_model = variants[base]
  if type(per_model) == "table" then
    if per_model[token] == true or per_model[candidate] == true then
      return true
    end
    for _, value in ipairs(per_model) do
      if matches(value) then
        return true
      end
    end
  end
  for _, value in ipairs(variants) do
    if matches(value) then
      return true
    end
  end
  return false
end

local function is_native_variant(base, token, options)
  local candidate = base .. "[" .. token .. "]"
  if options then
    if type(options.is_native_variant) == "function" then
      local accepted = options.is_native_variant(base, token, candidate)
      if accepted ~= nil then
        return accepted == true
      end
    end
    if table_contains_variant(options.native_variants, base, token, candidate) then
      return true
    end
    if table_contains_variant(options.runtime_models, base, token, candidate) then
      return true
    end
  end

  return candidate == "claude-opus-4-6[1m]"
end

function M.parse_budget(value)
  if type(value) ~= "string" and type(value) ~= "number" then
    return nil, "context limit must be a number or string"
  end
  return parse_budget(tostring(value))
end

function M.is_effort(value)
  return known_effort[value] == true
end

-- Omitted effort and limit fields inherit from current. Runtime metadata can
-- recognize more native variants through options.runtime_models or a predicate.
function M.parse(expression, current, options)
  if type(expression) ~= "string" then
    return nil, "model expression must be a string"
  end
  local selector = trim(expression)
  if selector == "" then
    return nil, "model expression cannot be empty"
  end

  current = current or {}
  options = options or {}
  local effort = current.effort
  local context_limit_tokens = current.context_limit_tokens

  local before_effort, possible_effort = selector:match("^(.*):([%a]+)$")
  if before_effort and known_effort[possible_effort] then
    selector = before_effort
    effort = possible_effort
  end

  local explicit_base, explicit_limit = selector:match("^(.-)%[limit=([^%[%]]+)%]$")
  if explicit_base then
    local parsed, err = parse_budget(explicit_limit)
    if not parsed then
      return nil, err
    end
    selector = explicit_base
    context_limit_tokens = parsed
  else
    local base, final_group = selector:match("^(.-)%[([^%[%]]+)%]$")
    if base then
      local parsed = parse_budget(final_group)
      if parsed then
        local earlier_base, earlier_group = base:match("^(.-)%[([^%[%]]+)%]$")
        local earlier_numeric = earlier_group and parse_budget(earlier_group) ~= nil
        if earlier_numeric or not is_native_variant(base, final_group, options) then
          selector = base
          context_limit_tokens = parsed
        end
      end
    end
  end

  selector = trim(selector)
  if selector == "" then
    return nil, "runtime model selector cannot be empty"
  end

  return {
    model = selector,
    effort = effort,
    context_limit_tokens = context_limit_tokens,
  }
end

return M
