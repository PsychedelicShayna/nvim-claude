local M = {}

local api = vim.api
local documents = {}
local document_serial = 0

local function valid_buffer(bufnr)
  return type(bufnr) == "number" and api.nvim_buf_is_valid(bufnr) and api.nvim_buf_is_loaded(bufnr)
end

local function buffer_text(bufnr)
  local lines = api.nvim_buf_get_lines(bufnr, 0, -1, true)
  local text = table.concat(lines, "\n")
  local endofline = api.nvim_get_option_value("endofline", { buf = bufnr })
  if endofline and (#lines > 1 or (lines[1] or "") ~= "") then
    text = text .. "\n"
  end
  return text, lines
end

local function state_for(bufnr)
  local state = documents[bufnr]
  if state then
    return state
  end
  document_serial = document_serial + 1
  state = {
    id = ("buffer-%d-%d"):format(bufnr, document_serial),
    serial = document_serial,
    revision_serial = 0,
  }
  documents[bufnr] = state
  pcall(api.nvim_buf_attach, bufnr, false, {
    on_detach = function(_, detached_bufnr)
      if detached_bufnr == bufnr and documents[bufnr] == state then
        documents[bufnr] = nil
      end
    end,
  })
  return state
end

local function next_revision(state)
  state.revision_serial = state.revision_serial + 1
  return ("r%d-%d"):format(state.serial, state.revision_serial)
end

local function revision_for(state, text, changedtick)
  if state.baseline and state.baseline.text == text then
    return state.baseline.revision
  end
  if state.observed and state.observed.text == text then
    return state.observed.revision
  end
  local revision = next_revision(state)
  state.observed = {
    revision = revision,
    text = text,
    changedtick = changedtick,
  }
  return revision
end

local function utf8_boundary(text, count)
  count = math.max(0, math.min(count, #text))
  while count > 0 and count < #text do
    local byte = text:byte(count + 1)
    if not byte or byte < 0x80 or byte > 0xbf then
      break
    end
    count = count - 1
  end
  return count
end

local function splice_diff(base, current, document_id, base_revision, revision)
  local max_prefix = math.min(#base, #current)
  local prefix = 0
  while prefix < max_prefix and base:byte(prefix + 1) == current:byte(prefix + 1) do
    prefix = prefix + 1
  end
  prefix = utf8_boundary(base, prefix)
  prefix = utf8_boundary(current, prefix)

  local max_suffix = math.min(#base - prefix, #current - prefix)
  local suffix = 0
  while suffix < max_suffix
    and base:byte(#base - suffix) == current:byte(#current - suffix)
  do
    suffix = suffix + 1
  end
  while suffix > 0 do
    local base_start = #base - suffix
    local current_start = #current - suffix
    if utf8_boundary(base, base_start) == base_start
      and utf8_boundary(current, current_start) == current_start
    then
      break
    end
    suffix = suffix - 1
  end

  return {
    kind = "diff",
    document_id = document_id,
    base_revision = base_revision,
    revision = revision,
    encoding = "UTF-8 byte splice; start_byte is zero-based",
    start_byte = prefix,
    delete_text = base:sub(prefix + 1, #base - suffix),
    insert_text = current:sub(prefix + 1, #current - suffix),
  }
end

local function encoded_size(value)
  local ok, encoded = pcall(vim.json.encode, value)
  if ok then
    return #encoded
  end
  return math.huge
end

local function target_bounds(target)
  if not target then
    return nil, "target bounds are required for an excerpt"
  end
  if target.start_row ~= nil and target.end_row ~= nil then
    return target
  end
  if target[1] and target[1].start and target[1]["end"] then
    local first_row = target[1].start[1]
    local last_row = target[1]["end"][1]
    for _, item in ipairs(target) do
      first_row = math.min(first_row, item.start[1])
      last_row = math.max(last_row, item["end"][1])
    end
    return { start_row = first_row, end_row = last_row }
  end
  local ok, target_module = pcall(require, "nvim-claude.target")
  if not ok then
    return nil, "target module is unavailable"
  end
  return target_module.bounds(target)
end

local function excerpt_context(state, revision, lines, target, max_bytes, endofline)
  local bounds, bounds_error = target_bounds(target)
  if not bounds then
    return nil, bounds_error
  end
  local line_count = #lines
  local first = math.max(0, math.min(bounds.start_row, line_count - 1))
  local last = math.max(first, math.min(bounds.end_row, line_count - 1))

  local function build(start_row, end_row)
    local excerpt_lines = {}
    for row = start_row, end_row do
      excerpt_lines[#excerpt_lines + 1] = lines[row + 1]
    end
    local excerpt = table.concat(excerpt_lines, "\n")
    if end_row < line_count - 1 or (end_row == line_count - 1 and endofline and excerpt ~= "") then
      excerpt = excerpt .. "\n"
    end
    return {
      kind = "excerpt",
      document_id = state.id,
      revision = revision,
      coordinates = "zero-based rows; end_row inclusive",
      start_row = start_row,
      end_row = end_row,
      omitted_before_lines = start_row,
      omitted_after_lines = line_count - end_row - 1,
      text = excerpt,
    }
  end

  local context = build(first, last)
  if encoded_size(context) > max_bytes then
    return nil, "the intact target does not fit in the context allowance"
  end

  local before = first - 1
  local after = last + 1
  while before >= 0 or after < line_count do
    local candidates = {}
    if before >= 0 then
      candidates[#candidates + 1] = { before, last, "before" }
    end
    if after < line_count then
      candidates[#candidates + 1] = { first, after, "after" }
    end
    local accepted = false
    for _, candidate in ipairs(candidates) do
      local proposed = build(candidate[1], candidate[2])
      if encoded_size(proposed) <= max_bytes then
        context = proposed
        first, last = candidate[1], candidate[2]
        before = first - 1
        after = last + 1
        accepted = true
        break
      end
      if candidate[3] == "before" then
        before = -1
      else
        after = line_count
      end
    end
    if not accepted and before < 0 and after >= line_count then
      break
    end
  end
  return context
end

local function document_metadata(bufnr, state)
  local name = api.nvim_buf_get_name(bufnr)
  return {
    id = state.id,
    filetype = api.nvim_get_option_value("filetype", { buf = bufnr }),
    path = name ~= "" and name or nil,
  }
end

-- prepare is deliberately side-effect free with respect to the accepted baseline.
-- Call accept only after the runtime confirms that it accepted the request.
function M.prepare(bufnr, opts)
  opts = opts or {}
  bufnr = bufnr or api.nvim_get_current_buf()
  if not valid_buffer(bufnr) then
    return nil, "source buffer was deleted or unloaded"
  end

  local state = state_for(bufnr)
  local text, lines = buffer_text(bufnr)
  local changedtick = api.nvim_buf_get_changedtick(bufnr)
  local revision = revision_for(state, text, changedtick)
  local snapshot = {
    kind = "snapshot",
    document_id = state.id,
    revision = revision,
    text = text,
  }
  local context
  local baseline = state.baseline

  if baseline and baseline.text == text then
    context = {
      kind = "unchanged",
      document_id = state.id,
      revision = baseline.revision,
    }
    revision = baseline.revision
  elseif baseline and baseline.can_diff then
    local diff = splice_diff(baseline.text, text, state.id, baseline.revision, revision)
    if encoded_size(diff) < encoded_size(snapshot) then
      context = diff
    else
      context = snapshot
    end
  else
    context = snapshot
  end

  local max_bytes = opts.max_bytes
  if max_bytes and encoded_size(context) > max_bytes then
    local excerpt, excerpt_error = excerpt_context(
      state,
      revision,
      lines,
      opts.target or opts.bounds or opts.targets,
      max_bytes,
      api.nvim_get_option_value("endofline", { buf = bufnr })
    )
    if not excerpt then
      return nil, excerpt_error
    end
    context = excerpt
  end

  local can_diff_after
  if context.kind == "snapshot" or context.kind == "diff" then
    can_diff_after = true
  elseif context.kind == "unchanged" then
    can_diff_after = baseline and baseline.can_diff or false
  else
    can_diff_after = false
  end
  local targets = opts.targets
  if not targets and opts.target and opts.target.segments then
    local ok, target_module = pcall(require, "nvim-claude.target")
    if not ok then
      return nil, "target module is unavailable"
    end
    local envelope, envelope_error = target_module.to_envelope(opts.target)
    if not envelope then
      return nil, envelope_error
    end
    targets = envelope
  end


  return {
    document = document_metadata(bufnr, state),
    context = context,
    revision = revision,
    targets = targets,
    pending = {
      bufnr = bufnr,
      document_id = state.id,
      revision = revision,
      text = text,
      changedtick = changedtick,
      can_diff_after = can_diff_after,
      context_kind = context.kind,
    },
  }
end

M.capture = M.prepare

function M.accept(prepared)
  local pending = prepared and (prepared.pending or prepared)
  if type(pending) ~= "table" or type(pending.bufnr) ~= "number" then
    return nil, "invalid pending context"
  end
  local state = documents[pending.bufnr]
  if not state or state.id ~= pending.document_id then
    return nil, "pending context belongs to an unknown document"
  end
  state.baseline = {
    revision = pending.revision,
    text = pending.text,
    changedtick = pending.changedtick,
    can_diff = pending.can_diff_after == true,
    context_kind = pending.context_kind,
  }
  return state.baseline
end

M.mark_accepted = M.accept

function M.invalidate(bufnr)
  if bufnr == nil then
    for _, state in pairs(documents) do
      state.baseline = nil
    end
    return
  end
  local state = documents[bufnr]
  if state then
    state.baseline = nil
  end
end

function M.rejected(prepared, uncertain)
  if not uncertain then
    return
  end
  local pending = prepared and (prepared.pending or prepared)
  if pending and pending.bufnr then
    M.invalidate(pending.bufnr)
  end
end

function M.baseline(bufnr)
  local state = documents[bufnr]
  if not state or not state.baseline then
    return nil
  end
  return vim.deepcopy(state.baseline)
end

function M.document_id(bufnr)
  if not valid_buffer(bufnr) then
    return nil
  end
  return state_for(bufnr).id
end

function M.drop(bufnr)
  documents[bufnr] = nil
end

function M.reset()
  documents = {}
end

return M
