local M = {}

local baselines = {}

local function revision(buf, text)
  return ("buffer-%d-%d-%s"):format(buf, vim.api.nvim_buf_get_changedtick(buf), vim.fn.sha256(text):sub(1, 12))
end

local function snapshot(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local text = table.concat(lines, "\n")
  return { lines = lines, text = text, revision = revision(buf, text) }
end

local function slice(values, first, last)
  if last < first then
    return {}
  end
  return vim.list_slice(values, first, last)
end

local function line_diff(before, after, base_revision, next_revision, document_id)
  local prefix = 0
  local shortest = math.min(#before, #after)
  while prefix < shortest and before[prefix + 1] == after[prefix + 1] do
    prefix = prefix + 1
  end
  local before_suffix, after_suffix = #before, #after
  while before_suffix > prefix and after_suffix > prefix and before[before_suffix] == after[after_suffix] do
    before_suffix = before_suffix - 1
    after_suffix = after_suffix - 1
  end
  return {
    kind = "diff",
    document_id = document_id,
    base_revision = base_revision,
    revision = next_revision,
    format = "zero-based line span; end-exclusive",
    start_row = prefix,
    end_row = before_suffix,
    deleted = slice(before, prefix + 1, before_suffix),
    inserted = slice(after, prefix + 1, after_suffix),
  }
end

local function excerpt(buf, state, target, available)
  local first, last = math.huge, -1
  for _, segment in ipairs(target.segments) do
    first = math.min(first, segment.start_row)
    last = math.max(last, segment.end_row)
  end
  local lines = state.lines
  local start_row, end_row = first, last
  local size = 0
  for row = start_row, end_row do
    size = size + #(lines[row + 1] or "") + 1
  end
  if size > available then
    return nil, "The target alone cannot fit inside the configured context budget"
  end
  while true do
    local changed = false
    if start_row > 0 then
      local cost = #(lines[start_row] or "") + 1
      if size + cost <= available then
        start_row, size, changed = start_row - 1, size + cost, true
      end
    end
    if end_row < #lines - 1 then
      local cost = #(lines[end_row + 2] or "") + 1
      if size + cost <= available then
        end_row, size, changed = end_row + 1, size + cost, true
      end
    end
    if not changed then
      break
    end
  end
  return {
    kind = "excerpt",
    revision = state.revision,
    start_row = start_row,
    end_row = end_row + 1,
    omitted_before = start_row,
    omitted_after = #lines - end_row - 1,
    text = table.concat(vim.list_slice(lines, start_row + 1, end_row + 1), "\n"),
  }
end

function M.build(buf, target, instruction, config, system_prompt)
  if not target then
    return nil, nil
  end
  local state = snapshot(buf)
  local document_id = "buffer-" .. buf
  local baseline = baselines[buf]
  local context
  if baseline and baseline.revision == state.revision then
    context = { kind = "unchanged", revision = state.revision }
  elseif baseline then
    context = line_diff(baseline.lines, state.lines, baseline.revision, state.revision, document_id)
    local encoded = vim.json.encode(context)
    if #encoded >= #state.text then
      context = { kind = "snapshot", revision = state.revision, text = state.text }
    end
  else
    context = { kind = "snapshot", revision = state.revision, text = state.text }
  end

  local available = config.context_limit_tokens
    - config.runtime_overhead_tokens
    - config.output_reserve_tokens
    - #system_prompt
    - #instruction
    - 4096
  if context.text and #context.text > available then
    local clipped, err = excerpt(buf, state, target, available)
    if not clipped then
      return nil, nil, err
    end
    context = clipped
  end
  return context, state
end

function M.confirm(buf, state)
  if state then
    baselines[buf] = state
  end
end

function M.invalidate(buf)
  if buf then
    baselines[buf] = nil
  else
    baselines = {}
  end
end

function M.info()
  local count = 0
  for _ in pairs(baselines) do
    count = count + 1
  end
  return { buffers = count }
end

return M
