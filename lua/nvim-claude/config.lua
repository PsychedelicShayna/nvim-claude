local M = {}

M.defaults = {
  python = nil, -- interpreter used to create the venv; nil finds python3/python
  model = "claude-haiku-5-5",
  effort = "low",
  context_limit = 100000,
  on_limit = "ask", -- "ask" | "new" | "compact"
  expire_minutes = 60, -- unsaved conversations start fresh after this much idle time
  sticky = false,
  watermarks = "allow", -- "allow" | "remove" | "replace"
  context_lines = 400, -- buffers longer than this are sent as an excerpt around the target
  models = {}, -- extra exact slugs (strings or { value = ..., label = ... })
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
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  opts = opts or {}
  local keys = opts.keys
  local merged = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  if keys == false then
    merged.keys = false
  end
  M.options = merged
  return merged
end

return M
