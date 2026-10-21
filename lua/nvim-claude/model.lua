local M = {}

M.presets = { 50000, 90000, 100000, 124000, 150000, 164000, 200000, 224000,
  256000, 258000, 274000, 278000, 300000, 374000, 378000, 384000,
  412000, 456000, 500000, 512000, 600000, 650000, 700000, 750000,
  800000, 850000, 900000, 950000, 980000 }
local efforts = { low = true, medium = true, high = true, xhigh = true, max = true }
local function tokens(text)
  local amount, suffix = text:lower():match('^(%d+)([km]?)$')
  if not amount then return nil end
  local n = tonumber(amount) * (({ k = 1000, m = 1000000 })[suffix] or 1)
  if not n or n < 1 or n > 10000000 then return nil end
  return n
end
M.tokens = tokens

function M.parse(expression, current, catalogue)
  local raw = vim.trim(expression)
  if raw == '' then return nil, 'A model ID is required' end
  local effort = raw:match(':([a-z]+)$')
  if efforts[effort] then raw = raw:sub(1, #raw - #effort - 1) else effort = nil end
  local model, budget = raw, nil
  local explicit = raw:match('%[limit=([^%]]+)%]$')
  if explicit then
    budget = tokens(explicit)
    if not budget then return nil, 'Invalid local token budget' end
    model = raw:sub(1, #raw - #explicit - 8)
  else
    local last = raw:match('%[([^%]]+)%]$')
    if last and tokens(last) then
      local preceding = raw:sub(1, #raw - #last - 2)
      local native = raw == 'claude-opus-4-6[1m]'
      for _, item in ipairs(catalogue or {}) do
        if item.id == raw then native = true; break end
      end
      if preceding:match('%[[^%]]+%]$') or not native then
        budget, model = tokens(last), preceding
      end
    end
  end
  if model == '' or model:find('%s') then return nil, 'Invalid model ID' end
  local chosen = nil
  for _, item in ipairs(catalogue or {}) do if item.id == model then chosen = item; break end end
  if effort and chosen and chosen.efforts and not vim.tbl_contains(chosen.efforts, effort) then
    return nil, 'Effort ' .. effort .. ' is not supported by ' .. model
  end
  local keep_effort = current.effort
  if model ~= current.model and (not chosen or
    (chosen.efforts and not vim.tbl_contains(chosen.efforts, keep_effort))) then
    keep_effort = nil
  end
  return { model = model, effort = effort or keep_effort,
    context_limit_tokens = budget or current.context_limit_tokens }
end

function M.label(config)
  return config.model .. (config.context_limit_tokens and
    (' [%s tokens]'):format(config.context_limit_tokens) or ' [model default]') ..
    (config.effort and ':' .. config.effort or '')
end

return M
