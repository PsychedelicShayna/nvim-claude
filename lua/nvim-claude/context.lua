local M = {}
local baselines = {}
local revision = 0

local function snapshot(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") .. "\n"
end

local function document(buf)
  return { id = "buffer-" .. buf, filetype = vim.bo[buf].filetype }
end

function M.build(target, limit)
  if not target then return nil, nil end
  local buf = target.buf
  local current = snapshot(buf)
  revision = revision + 1
  local next_revision = "r" .. revision
  local previous = baselines[buf]
  local context
  if previous and previous.text == current then
    context = { kind = "unchanged", revision = previous.revision }
  elseif previous then
    local diff = vim.diff(previous.text, current, { result_type = "unified", ctxlen = 3 })
    if #diff < #current then
      context = { kind = "diff", document_id = "buffer-" .. buf, base_revision = previous.revision, revision = next_revision, text = diff }
    end
  end
  if not context then
    local byte_budget = math.max(4096, (limit - 24000) * 2)
    if #current <= byte_budget then
      context = { kind = "snapshot", revision = next_revision, text = current }
    else
      local first, last = math.huge, 0
      for _, segment in ipairs(target.segments) do
        first = math.min(first, segment.start_row)
        last = math.max(last, segment.end_row)
      end
      first, last = math.max(0, first - 80), math.min(vim.api.nvim_buf_line_count(buf), last + 81)
      context = {
        kind = "excerpt", revision = next_revision,
        start_row = first, end_row = last,
        omitted_before = first > 0, omitted_after = last < vim.api.nvim_buf_line_count(buf),
        text = table.concat(vim.api.nvim_buf_get_lines(buf, first, last, false), "\n") .. "\n",
      }
    end
  end
  return { document = document(buf), context = context }, { buf = buf, text = current, revision = next_revision }
end

function M.accept(candidate)
  if candidate then baselines[candidate.buf] = candidate end
end

function M.reset() baselines = {} end

return M
