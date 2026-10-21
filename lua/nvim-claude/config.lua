local M = {}

M.defaults = {
  python = nil,
  model = "claude-haiku-5-5",
  effort = "low",
  context_limit_tokens = 100000,
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
  float = {
    border = "single",
    max_width = 88,
    max_height = 24,
  },
}

local valid_efforts = { low = true, medium = true, high = true, xhigh = true, max = true }

local function copy(value)
  return vim.deepcopy(value)
end

function M.resolve(user)
  user = user or {}
  if type(user) ~= "table" then
    error("nvim-claude setup expects a table")
  end
  local resolved = vim.tbl_deep_extend("force", copy(M.defaults), user)
  resolved._explicit_keys = {}
  if user.keys == false then
    resolved.keys = false
  elseif user.keys ~= nil then
    if type(user.keys) ~= "table" then
      error("nvim-claude opts.keys must be a table or false")
    end
    for name in pairs(user.keys) do
      resolved._explicit_keys[name] = true
    end
  end
  if not valid_efforts[resolved.effort] then
    error("nvim-claude effort must be low, medium, high, xhigh, or max")
  end
  if resolved.context_limit_tokens ~= nil and (type(resolved.context_limit_tokens) ~= "number" or resolved.context_limit_tokens < 1) then
    error("nvim-claude context_limit_tokens must be a positive number or nil")
  end
  if not ({ allow = true, remove = true, replace = true })[resolved.punctuation] then
    error("nvim-claude punctuation must be allow, remove, or replace")
  end
  return resolved
end

return M
