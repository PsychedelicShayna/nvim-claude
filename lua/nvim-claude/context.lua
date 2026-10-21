local M = {}
local api = vim.api
local baselines = {}

local function revision(buf)
  return ("buffer-%d-r%d"):format(buf, api.nvim_buf_get_changedtick(buf))
end

local function buffer_text(buf)
  return table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local function byte_budget(limit)
  if not limit then return math.huge end
  return math.max(4096, limit - 40000)
end

local function target_rows(target)
  local first, last = math.huge, 0
  for _, item in ipairs(target.segments) do
    first = math.min(first, item.start_row)
    last = math.max(last, item.end_row)
  end
  return first == math.huge and 0 or first, last
end

local function excerpt(buf, target, maximum)
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  local first, last = target_rows(target)
  local low, high = math.max(0, first - 20), math.min(#lines - 1, last + 20)
  local function current()
    return table.concat(vim.list_slice(lines, low + 1, high + 1), "\n")
  end
  local text = current()
  while #text > maximum and (low < first or high > last) do
    if first - low >= high - last and low < first then low = low + 1
    elseif high > last then high = high - 1
    else break end
    text = current()
  end
  return {
    kind = "excerpt",
    revision = revision(buf),
    text = text,
    start_row = low,
    end_row_exclusive = high + 1,
    omitted_before = low > 0,
    omitted_after = high < #lines - 1,
  }
end

function M.build(target, limit)
  local buf = target.buf
  local text = buffer_text(buf)
  local current_revision = revision(buf)
  local maximum = byte_budget(limit)
  local previous = baselines[buf]
  local context
  if previous and previous.text == text then
    context = { kind = "unchanged", revision = previous.revision }
  elseif previous then
    local diff = vim.diff(previous.text, text, { result_type = "unified", ctxlen = 3 })
    if #diff < #text and #diff <= maximum then
      context = {
        kind = "diff",
        document_id = "buffer-" .. buf,
        base_revision = previous.revision,
        revision = current_revision,
        text = diff,
      }
    end
  end
  if not context then
    if #text <= maximum then
      context = { kind = "snapshot", revision = current_revision, text = text }
    else
      context = excerpt(buf, target, maximum)
    end
  end
  return {
    document = {
      id = "buffer-" .. buf,
      filetype = vim.bo[buf].filetype,
      path = api.nvim_buf_get_name(buf) ~= "" and api.nvim_buf_get_name(buf) or nil,
    },
    context = context,
    pending_baseline = { buf = buf, revision = current_revision, text = text },
  }
end

function M.accept(pending)
  if pending then baselines[pending.buf] = { revision = pending.revision, text = pending.text } end
end

function M.invalidate(buf)
  if buf then baselines[buf] = nil else baselines = {} end
end

return M
