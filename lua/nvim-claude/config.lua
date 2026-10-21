local M = {}

M.defaults = {
  python = nil,
  model = "claude-haiku-5-5",
  effort = "low",
  context_limit_tokens = 100000,
  cache_ttl_seconds = 3600,
  keys = {
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
  },
  punctuation = "allow",
}

M.current = vim.deepcopy(M.defaults)

function M.setup(opts)
  opts = opts or {}
  M.current = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  if opts.keys == false then
    M.current.keys = false
  end
  return M.current
end

local efforts = { low = true, medium = true, high = true, xhigh = true, max = true }

local function amount(value)
  local number, suffix = value:match("^(%d+)([kKmM]?)$")
  if not number then return nil end
  local multiplier = suffix:lower() == "k" and 1000 or suffix:lower() == "m" and 1000000 or 1
  return tonumber(number) * multiplier
end

function M.parse_model(expression, previous)
  local result = vim.deepcopy(previous or M.current)
  local value = vim.trim(expression)
  local stem, effort = value:match("^(.*):([^:]+)$")
  if stem and efforts[effort] then
    value, result.effort = stem, effort
  end
  local explicit = value:match("%[limit=([^%]]+)%]$")
  if explicit then
    local parsed = amount(explicit)
    assert(parsed, "invalid context limit")
    result.context_limit_tokens = parsed
    value = value:gsub("%[limit=[^%]]+%]$", "")
  else
    local prefix, last, groups = value:match("^(.-)%[([^%]]+)%]$"), nil, 0
    for _ in value:gmatch("%[[^%]]+%]") do groups = groups + 1 end
    last = value:match("%[([^%]]+)%]$")
    local parsed = last and amount(last) or nil
    local native_one_m = groups == 1 and last and last:lower() == "1m" and value:match("^claude%-opus%-4%-6")
    if parsed and not native_one_m then
      result.context_limit_tokens = parsed
      value = value:sub(1, #value - #last - 2)
    end
  end
  assert(value ~= "", "model is required")
  result.model = value
  return result
end

return M
