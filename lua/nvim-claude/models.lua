-- Model catalogue, picker, and `slug[limit]:effort` expressions.
local config = require("nvim-claude.config")
local bridge = require("nvim-claude.bridge")
local session = require("nvim-claude.session")

local M = {}

local EFFORTS = { "low", "medium", "high", "xhigh", "max" }
local EFFORT_SET = {}
for _, e in ipairs(EFFORTS) do
  EFFORT_SET[e] = true
end

-- Used when the runtime does not announce models, merged with live entries.
local FALLBACK = {
  { value = "claude-haiku-5-5", label = "Haiku 5.5" },
  { value = "claude-sonnet-5-5", label = "Sonnet 5.5" },
  { value = "claude-opus-5-5", label = "Opus 5.5" },
  { value = "claude-fable-5-1", label = "Fable 5.1" },
  { value = "claude-opus-5", label = "Opus 5" },
  { value = "claude-sonnet-5", label = "Sonnet 5" },
  { value = "claude-fable-5", label = "Fable 5" },
  { value = "claude-opus-4-8", label = "Opus 4.8" },
  { value = "claude-opus-4-7", label = "Opus 4.7" },
  { value = "claude-opus-4-6", label = "Opus 4.6" },
  { value = "claude-opus-4-6[1m]", label = "Opus 4.6 (1M)" },
  { value = "claude-sonnet-4-6", label = "Sonnet 4.6" },
  { value = "claude-sonnet-4-6[1m]", label = "Sonnet 4.6 (1M)" },
  { value = "claude-haiku-4-5", label = "Haiku 4.5" },
}

local PRESETS = {
  "50k", "90k", "100k", "124k", "150k", "164k", "200k", "224k", "256k", "258k", "274k", "278k", "300k",
  "374k", "378k", "384k", "412k", "456k", "500k", "512k", "600k", "650k", "700k", "750k", "800k", "850k",
  "900k", "950k", "980k",
}

local live = nil -- last announced list

local function parse_count(s)
  local n, unit = (s or ""):lower():match("^(%d+%.?%d*)([km]?)$")
  if not n then
    return nil
  end
  n = tonumber(n)
  if unit == "k" then
    n = n * 1000
  elseif unit == "m" then
    n = n * 1000000
  end
  return math.floor(n + 0.5)
end
M.parse_count = parse_count

-- Parse `slug[native][limit]:effort`. Returns { model, limit?, effort? } or nil, err.
function M.parse(expr)
  expr = vim.trim(expr or "")
  if expr == "" then
    return nil, "empty model expression"
  end
  local out = {}
  local head, eff = expr:match("^(.-):(%a+)$")
  if head and EFFORT_SET[eff:lower()] then
    expr, out.effort = head, eff:lower()
  end
  local explicit = expr:match("%[limit=([%w%.]+)%]$")
  if explicit then
    out.limit = parse_count(explicit)
    if not out.limit then
      return nil, "bad limit: " .. explicit
    end
    expr = expr:gsub("%[limit=[%w%.]+%]$", "")
  else
    local base, last = expr:match("^(.-)%[([%d%.]+[kKmM]?)%]$")
    if base then
      local prior = base:match("%[[%d%.]+[kKmM]?%]$")
      -- A lone [1m] directly after the slug is a native variant, not a limit.
      if prior or last:lower() ~= "1m" then
        out.limit = parse_count(last)
        expr = base
      end
    end
  end
  out.model = expr
  if out.model == "" then
    return nil, "missing model slug"
  end
  return out
end

function M.apply(parsed)
  local s = session.state
  local changed_model = parsed.model and parsed.model ~= s.model
  if parsed.model then
    s.model = parsed.model
  end
  if parsed.effort ~= nil then
    s.effort = parsed.effort ~= "" and parsed.effort or nil
  end
  if parsed.limit ~= nil then
    s.limit = parsed.limit ~= 0 and parsed.limit or nil
  end
  session.persist()
  local msg = string.format(
    "model %s · effort %s · limit %s",
    s.model or "default",
    s.effort or "default",
    s.limit and session.fmt_k(s.limit) or "model default"
  )
  if changed_model and session.convo then
    msg = msg .. " (applies from the next request in this conversation)"
  end
  bridge.notify(msg)
end

function M.apply_expression(expr)
  local parsed, err = M.parse(expr)
  if not parsed then
    return bridge.notify(err, vim.log.levels.ERROR)
  end
  M.apply(parsed)
end

local function catalogue()
  local out, seen = {}, {}
  local function add(item)
    if type(item) == "string" then
      item = { value = item }
    end
    local value = item.value
    if value and not seen[value] then
      seen[value] = true
      out[#out + 1] = item
    end
  end
  for _, m in ipairs(live or {}) do
    if m.value ~= "default" then
      local label = m.displayName or m.value
      if m.resolvedModel and m.resolvedModel ~= m.value then
        label = label .. " → " .. m.resolvedModel
      end
      add({ value = m.value, label = label, efforts = m.supportedEffortLevels, live = true })
    end
  end
  for _, m in ipairs(config.options.models or {}) do
    add(m)
  end
  for _, m in ipairs(FALLBACK) do
    add(m)
  end
  return out
end

function M.slugs()
  return vim.tbl_map(function(m)
    return m.value
  end, catalogue())
end

local function pick_limit(parsed)
  local items = { "keep current (" .. (session.state.limit and session.fmt_k(session.state.limit) or "model default") .. ")", "model default (no limit)" }
  vim.list_extend(items, PRESETS)
  items[#items + 1] = "custom…"
  vim.ui.select(items, { prompt = "Context limit" }, function(choice, idx)
    if not choice then
      return
    end
    if idx == 2 then
      parsed.limit = 0
    elseif choice == "custom…" then
      local v = vim.fn.input("Context limit (e.g. 318k): ")
      local n = parse_count(v)
      if not n then
        return bridge.notify("not a token count: " .. v, vim.log.levels.ERROR)
      end
      parsed.limit = n
    elseif idx > 2 then
      parsed.limit = parse_count(choice)
    end
    M.apply(parsed)
  end)
end

local function pick_effort(item, parsed)
  local efforts = item.efforts
  if type(efforts) == "table" and #efforts == 0 then
    parsed.effort = ""
    return pick_limit(parsed)
  end
  local items = vim.deepcopy(type(efforts) == "table" and efforts or EFFORTS)
  table.insert(items, 1, "model default")
  vim.ui.select(items, {
    prompt = "Effort" .. (type(efforts) == "table" and "" or " (support unknown for this model)"),
  }, function(choice)
    if not choice then
      return
    end
    parsed.effort = choice == "model default" and "" or choice
    pick_limit(parsed)
  end)
end

local function show_picker()
  local items = catalogue()
  items[#items + 1] = { value = "__manual", label = "enter a slug or expression…" }
  vim.ui.select(items, {
    prompt = "Claude model" .. (live and "" or " (fallback list; live catalogue unavailable)"),
    format_item = function(item)
      local mark = item.value == session.state.model and "● " or "  "
      if item.value == "__manual" then
        return "  " .. item.label
      end
      return mark .. (item.label or item.value) .. ((item.label and item.label ~= item.value) and ("  [" .. item.value .. "]") or "")
    end,
  }, function(item)
    if not item then
      return
    end
    if item.value == "__manual" then
      return M.manual()
    end
    pick_effort(item, { model = item.value })
  end)
end

function M.pick()
  if live then
    return show_picker()
  end
  bridge.notify("loading model catalogue…")
  local done = false
  local timer = vim.defer_fn(function()
    if not done then
      done = true
      show_picker()
    end
  end, 20000)
  bridge.call("models", {}, function(err, res)
    if done then
      if not err then
        live = res
      end
      return
    end
    done = true
    pcall(function()
      timer:stop()
    end)
    if err then
      bridge.notify("live model list unavailable: " .. err, vim.log.levels.WARN)
    elseif type(res) == "table" and #res > 0 then
      live = res
    end
    show_picker()
  end)
end

function M.manual()
  local s = session.state
  local current = (s.model or "") .. (s.limit and ("[" .. session.fmt_k(s.limit) .. "]") or "") .. (s.effort and (":" .. s.effort) or "")
  vim.ui.input({ prompt = "Model (slug[limit]:effort): ", default = current }, function(v)
    if v and vim.trim(v) ~= "" then
      M.apply_expression(v)
    end
  end)
end

return M
