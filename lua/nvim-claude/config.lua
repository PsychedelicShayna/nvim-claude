local M = {}

local DEFAULT_KEYS = {
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

local function is_list(value)
  if vim.islist then
    return vim.islist(value)
  end
  return vim.tbl_islist(value)
end

local function copy(value, seen)
  if type(value) ~= "table" then
    return value
  end
  seen = seen or {}
  if seen[value] then
    return seen[value]
  end
  local result = {}
  seen[value] = result
  for key, child in pairs(value) do
    result[copy(key, seen)] = copy(child, seen)
  end
  return result
end

local function merge(base, override)
  if override == nil then
    return copy(base)
  end
  if type(base) ~= "table" or type(override) ~= "table" then
    return copy(override)
  end
  if is_list(base) or (next(override) ~= nil and is_list(override)) then
    return copy(override)
  end

  local result = copy(base)
  for key, value in pairs(override) do
    result[key] = merge(base[key], value)
  end
  return result
end

local function join(left, right)
  return left:gsub("/+$", "") .. "/" .. right
end

local function defaults()
  local data_dir = join(vim.fn.stdpath("data"), "nvim-claude")
  return {
    model = "claude-haiku-5-5",
    effort = "low",
    context_limit_tokens = 100000,
    punctuation = "allow",
    python = "python3",
    data_dir = data_dir,
    venv_dir = join(data_dir, "venv"),
    state_dir = join(vim.fn.stdpath("state"), "nvim-claude"),
    keys = copy(DEFAULT_KEYS),
  }
end

local configured

function M.setup(opts)
  if opts ~= nil and type(opts) ~= "table" then
    error("nvim-claude setup options must be a table")
  end

  opts = opts or {}
  configured = merge(defaults(), opts)
  if opts.data_dir ~= nil and opts.venv_dir == nil then
    configured.venv_dir = join(configured.data_dir, "venv")
  end
  if configured.keys ~= false and type(configured.keys) ~= "table" then
    error("nvim-claude keys must be a table or false")
  end
  return copy(configured)
end

function M.get()
  if configured == nil then
    configured = defaults()
  end
  return copy(configured)
end

function M.defaults()
  return defaults()
end

function M.default_keys()
  return copy(DEFAULT_KEYS)
end

return M
