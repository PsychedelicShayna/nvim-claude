local M = {}

local api = vim.api
local ns = api.nvim_create_namespace("nvim-claude-targets")
local serial = 0
local remembered = {}

local function next_serial()
  serial = serial + 1
  return serial
end

local function valid_buffer(bufnr)
  return type(bufnr) == "number" and api.nvim_buf_is_valid(bufnr) and api.nvim_buf_is_loaded(bufnr)
end

local function option(name, bufnr)
  return api.nvim_get_option_value(name, { buf = bufnr })
end

local function next_boundary(text, byte_col)
  if byte_col >= #text then
    return #text
  end
  local index = byte_col + 2
  while index <= #text do
    local byte = text:byte(index)
    if not byte or byte < 0x80 or byte > 0xbf then
      break
    end
    index = index + 1
  end
  return index - 1
end

local function utf8_start(text, byte_col)
  byte_col = math.max(0, math.min(byte_col, #text))
  while byte_col > 0 do
    local byte = text:byte(byte_col + 1)
    if not byte or byte < 0x80 or byte > 0xbf then
      break
    end
    byte_col = byte_col - 1
  end
  return byte_col
end

local function utf8_end(text, byte_col)
  byte_col = math.max(0, math.min(byte_col, #text))
  while byte_col > 0 and byte_col < #text do
    local byte = text:byte(byte_col + 1)
    if not byte or byte < 0x80 or byte > 0xbf then
      break
    end
    byte_col = byte_col - 1
  end
  return byte_col
end

local function byte_text(bufnr, start_row, start_col, end_row, end_col)
  return table.concat(api.nvim_buf_get_text(bufnr, start_row, start_col, end_row, end_col, {}), "\n")
end

local function split_text(text)
  local lines = {}
  local start = 1
  while true do
    local stop = text:find("\n", start, true)
    if not stop then
      lines[#lines + 1] = text:sub(start)
      return lines
    end
    lines[#lines + 1] = text:sub(start, stop - 1)
    start = stop + 1
  end
end

local function suffix_bytes(text, limit)
  local start = math.max(0, #text - limit)
  start = utf8_start(text, start)
  return text:sub(start + 1)
end

local function prefix_bytes(text, limit)
  local stop = utf8_end(text, math.min(#text, limit))
  return text:sub(1, stop)
end

local function boundary_at(bufnr, row, col, radius)
  radius = radius or 64
  local line_count = api.nvim_buf_line_count(bufnr)
  row = math.max(0, math.min(row, line_count - 1))
  local line = api.nvim_buf_get_lines(bufnr, row, row + 1, true)[1] or ""
  col = math.max(0, math.min(col, #line))

  local before = suffix_bytes(line:sub(1, col), radius)
  if col == 0 and row > 0 then
    local previous = api.nvim_buf_get_lines(bufnr, row - 1, row, true)[1] or ""
    before = suffix_bytes(previous, radius - 1) .. "\n"
  end

  local after = prefix_bytes(line:sub(col + 1), radius)
  if col == #line and row + 1 < line_count then
    local following = api.nvim_buf_get_lines(bufnr, row + 1, row + 2, true)[1] or ""
    after = "\n" .. prefix_bytes(following, radius - 1)
  end

  return { before = before, after = after }
end

local function display_width(text, start_col, tabstop)
  local width = 0
  local index = 0
  while index < #text do
    local finish = next_boundary(text, index)
    local char = text:sub(index + 1, finish)
    local absolute = start_col + width
    if char == "\t" then
      width = width + (tabstop - (absolute % tabstop))
    else
      width = width + vim.fn.strdisplaywidth(char)
    end
    index = finish
  end
  return width
end

local function screen_col(line, byte_col, tabstop)
  return display_width(line:sub(1, byte_col), 0, tabstop)
end

local function set_range_mark(bufnr, start_row, start_col, end_row, end_col)
  local opts = {
    end_row = end_row,
    end_col = end_col,
    right_gravity = true,
    end_right_gravity = start_row == end_row and start_col == end_col or false,
    undo_restore = true,
    invalidate = true,
    strict = true,
  }
  local ok, mark = pcall(api.nvim_buf_set_extmark, bufnr, ns, start_row, start_col, opts)
  if ok then
    return mark
  end
  opts.invalidate = nil
  return api.nvim_buf_set_extmark(bufnr, ns, start_row, start_col, opts)
end

local function delete_mark(bufnr, mark)
  if mark and api.nvim_buf_is_valid(bufnr) then
    pcall(api.nvim_buf_del_extmark, bufnr, ns, mark)
  end
end

local function resolve_segment(target, segment)
  if not valid_buffer(target.bufnr) then
    return nil, "source buffer was deleted or unloaded"
  end
  local mark = api.nvim_buf_get_extmark_by_id(target.bufnr, ns, segment.mark, { details = true })
  if #mark == 0 then
    return nil, "target extmark was deleted"
  end
  local details = mark[3] or {}
  if details.invalid == true or details.invalid == 1 then
    return nil, "target was deleted"
  end
  local end_row = details.end_row
  local end_col = details.end_col
  if end_row == nil or end_col == nil then
    return nil, "target range was lost"
  end
  return {
    start_row = mark[1],
    start_col = mark[2],
    end_row = end_row,
    end_col = end_col,
  }
end

local function segment_source(bufnr, range)
  return byte_text(bufnr, range.start_row, range.start_col, range.end_row, range.end_col)
end

local function make_segment(target, id, start_row, start_col, end_row, end_col, selected_text, source_text, extra)
  local segment = extra or {}
  segment.id = id
  segment.text = selected_text
  segment.source_text = source_text
  segment.mark = set_range_mark(target.bufnr, start_row, start_col, end_row, end_col)
  segment.boundary_start = boundary_at(target.bufnr, start_row, start_col)
  segment.boundary_end = boundary_at(target.bufnr, end_row, end_col)
  return segment
end

local function new_target(bufnr, kind, style)
  local id = next_serial()
  return {
    id = id,
    bufnr = bufnr,
    kind = kind,
    style = style,
    source_revision = api.nvim_buf_get_changedtick(bufnr),
    segments = {},
  }
end

local function visual_positions(opts)
  local bufnr = opts.bufnr or api.nvim_get_current_buf()
  local mode = opts.mode or vim.fn.mode(1)
  mode = mode:sub(1, 1)
  if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
    return nil, "a characterwise, linewise, or blockwise Visual selection is required"
  end
  local anchor = opts.anchor or vim.fn.getpos("v")
  local cursor = opts.cursor or vim.fn.getpos(".")
  anchor = { bufnr, anchor[2], anchor[3], anchor[4] or 0 }
  cursor = { bufnr, cursor[2], cursor[3], cursor[4] or 0 }
  return {
    bufnr = bufnr,
    mode = mode,
    anchor = anchor,
    cursor = cursor,
    exclusive = opts.exclusive == nil and vim.o.selection == "exclusive" or opts.exclusive,
  }
end

local function position_start(line, position)
  local col = position[3] or 1
  if col <= 0 then
    return 0
  end
  return math.min(#line, col - 1)
end

local function position_end(line, position)
  local col = position[3] or 1
  if col <= 0 or col > #line then
    return #line
  end
  local finish = next_boundary(line, col - 1)
  while finish < #line do
    local following = next_boundary(line, finish)
    local char = line:sub(finish + 1, following)
    if vim.fn.strdisplaywidth(char) ~= 0 then
      break
    end
    finish = following
  end
  return finish
end

local function capture_block(selection, positions, texts)
  local target = new_target(selection.bufnr, "block", "text")
  local tabstop = option("tabstop", selection.bufnr)
  for index, pair in ipairs(positions) do
    local start_pos, end_pos = pair[1], pair[2]
    local row = start_pos[2] - 1
    local line = api.nvim_buf_get_lines(selection.bufnr, row, row + 1, true)[1] or ""
    local start_col = position_start(line, start_pos)
    local end_col = position_end(line, end_pos)
    local start_offset = start_pos[4] or 0
    local end_offset = end_pos[4] or 0
    local preserve_before = start_offset
    local preserve_after = 0

    if end_offset > 0 and (end_pos[3] or 0) > 0 and end_pos[3] <= #line then
      local char_start = end_pos[3] - 1
      local char_end = next_boundary(line, char_start)
      local char = line:sub(char_start + 1, char_end)
      local char_screen_col = screen_col(line, char_start, tabstop)
      preserve_after = math.max(0, display_width(char, char_screen_col, tabstop) - end_offset)
    end

    local source = line:sub(start_col + 1, end_col)
    local start_screen_col = screen_col(line, start_col, tabstop)
    local segment = make_segment(
      target,
      ("target-%d-%d"):format(target.id, index - 1),
      row,
      start_col,
      row,
      end_col,
      texts[index] or "",
      source,
      {
        preserve_before = preserve_before,
        preserve_after = preserve_after,
        start_virtual_offset = start_offset,
        end_virtual_offset = end_offset,
        source_display_width = display_width(source, start_screen_col, tabstop),
      }
    )
    target.segments[#target.segments + 1] = segment
  end
  return target
end

local function capture_linewise(selection, positions)
  local first = positions[1][1]
  local last = positions[#positions][2]
  local start_row = first[2] - 1
  local end_row = last[2] - 1
  local lines = api.nvim_buf_get_lines(selection.bufnr, start_row, end_row + 1, true)
  local target = new_target(selection.bufnr, "contiguous", "line")
  local source = table.concat(lines, "\n")
  target.segments[1] = make_segment(
    target,
    ("target-%d"):format(target.id),
    start_row,
    0,
    end_row,
    #(lines[#lines] or ""),
    source,
    source,
    { line_count = #lines }
  )
  return target
end

local function capture_characterwise(selection, positions, texts)
  local first = positions[1][1]
  local last = positions[#positions][2]
  local start_row = first[2] - 1
  local end_row = last[2] - 1
  local first_line = api.nvim_buf_get_lines(selection.bufnr, start_row, start_row + 1, true)[1] or ""
  local last_line = api.nvim_buf_get_lines(selection.bufnr, end_row, end_row + 1, true)[1] or ""
  local start_col = position_start(first_line, first)
  local end_col = position_end(last_line, last)
  local source = byte_text(selection.bufnr, start_row, start_col, end_row, end_col)
  local selected = table.concat(texts, "\n")
  local target = new_target(selection.bufnr, "contiguous", "text")
  target.segments[1] = make_segment(
    target,
    ("target-%d"):format(target.id),
    start_row,
    start_col,
    end_row,
    end_col,
    selected,
    source,
    {}
  )
  return target
end

function M.capture_visual(opts)
  opts = opts or {}
  local selection, selection_error = visual_positions(opts)
  if not selection then
    return nil, selection_error
  end
  if not valid_buffer(selection.bufnr) then
    return nil, "source buffer is not loaded"
  end

  local region_opts = {
    type = selection.mode,
    exclusive = selection.exclusive,
    eol = true,
  }
  local ok_positions, positions = pcall(vim.fn.getregionpos, selection.anchor, selection.cursor, region_opts)
  local ok_text, texts = pcall(vim.fn.getregion, selection.anchor, selection.cursor, {
    type = selection.mode,
    exclusive = selection.exclusive,
  })
  if not ok_positions or not ok_text or #positions == 0 then
    return nil, "Neovim could not resolve the Visual selection"
  end

  local target
  if selection.mode == "\22" then
    target = capture_block(selection, positions, texts)
  elseif selection.mode == "V" then
    target = capture_linewise(selection, positions)
  else
    target = capture_characterwise(selection, positions, texts)
  end
  target.operation = opts.operation or "replace"
  return target
end

function M.capture_insert(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or api.nvim_get_current_buf()
  local winid = opts.winid or api.nvim_get_current_win()
  if not valid_buffer(bufnr) then
    return nil, "source buffer is not loaded"
  end
  if api.nvim_win_get_buf(winid) ~= bufnr then
    return nil, "origin window no longer displays the source buffer"
  end
  local cursor = opts.cursor or api.nvim_win_get_cursor(winid)
  local row = cursor[1] - 1
  local line = api.nvim_buf_get_lines(bufnr, row, row + 1, true)[1] or ""
  local col = math.max(0, math.min(cursor[2], #line))
  col = utf8_start(line, col)

  local target = new_target(bufnr, "contiguous", "text")
  target.insertion = true
  target.operation = opts.operation or "generate"
  target.insert_mode = opts.mode == "i"
  target.segments[1] = make_segment(
    target,
    ("target-%d"):format(target.id),
    row,
    col,
    row,
    col,
    "",
    "",
    {}
  )
  return target
end

M.capture_insertion = M.capture_insert

local function validate_segment(target, segment)
  local range, range_error = resolve_segment(target, segment)
  if not range then
    return nil, range_error
  end
  local current = segment_source(target.bufnr, range)
  if current ~= segment.source_text then
    return nil, ("target %s changed after capture"):format(segment.id)
  end

  if current == "" then
    local start_boundary = boundary_at(target.bufnr, range.start_row, range.start_col)
    local end_boundary = boundary_at(target.bufnr, range.end_row, range.end_col)
    if start_boundary.before ~= segment.boundary_start.before
      or start_boundary.after ~= segment.boundary_start.after
      or end_boundary.before ~= segment.boundary_end.before
      or end_boundary.after ~= segment.boundary_end.after
    then
      return nil, ("target boundary %s changed after capture"):format(segment.id)
    end
  end

  if target.kind == "block" and segment.source_display_width then
    local line = api.nvim_buf_get_lines(target.bufnr, range.start_row, range.start_row + 1, true)[1] or ""
    local tabstop = option("tabstop", target.bufnr)
    local start_screen_col = screen_col(line, range.start_col, tabstop)
    local width = display_width(current, start_screen_col, tabstop)
    if width ~= segment.source_display_width then
      return nil, ("virtual columns for target %s changed after capture"):format(segment.id)
    end
  end

  return range
end

function M.validate(target, require_modifiable)
  if type(target) ~= "table" or type(target.segments) ~= "table" then
    return false, "invalid target"
  end
  if not valid_buffer(target.bufnr) then
    return false, "source buffer was deleted or unloaded"
  end
  if require_modifiable and not option("modifiable", target.bufnr) then
    return false, "source buffer is not modifiable"
  end
  local ranges = {}
  for index, segment in ipairs(target.segments) do
    local range, err = validate_segment(target, segment)
    if not range then
      return false, err
    end
    ranges[index] = range
  end
  return true, ranges
end

local function ordered_replacements(target, response)
  local values = response
  if type(response) == "table" and response.status ~= nil then
    if response.status ~= "ok" then
      return nil, "edit response is not successful"
    end
    values = response.replacements
  end
  if type(values) ~= "table" then
    return nil, "edit response has no replacements"
  end

  local by_id = {}
  for _, replacement in ipairs(values) do
    if type(replacement) ~= "table" or type(replacement.id) ~= "string" or type(replacement.text) ~= "string" then
      return nil, "each replacement needs a string id and text"
    end
    if by_id[replacement.id] ~= nil then
      return nil, ("duplicate replacement id: %s"):format(replacement.id)
    end
    by_id[replacement.id] = replacement.text
  end

  local ordered = {}
  for index, segment in ipairs(target.segments) do
    local text = by_id[segment.id]
    if text == nil then
      return nil, ("missing replacement id: %s"):format(segment.id)
    end
    if target.kind == "block" and text:find("[\r\n]") then
      return nil, ("blockwise replacement %s contains a newline"):format(segment.id)
    end
    ordered[index] = { id = segment.id, text = text }
    by_id[segment.id] = nil
  end
  if next(by_id) ~= nil then
    return nil, ("unknown replacement id: %s"):format(next(by_id))
  end
  return ordered
end
function M.decode_result(target, raw)
  local response = raw
  if type(raw) == "string" then
    local ok, decoded = pcall(vim.json.decode, raw)
    if not ok then
      return nil, ("invalid edit JSON: %s"):format(decoded)
    end
    response = decoded
  end
  if type(response) ~= "table" then
    return nil, "edit result must be a JSON object"
  end
  if response.status == "needs_input" then
    if type(response.message) ~= "string" or response.replacements ~= nil then
      return nil, "needs_input requires a message and no replacements"
    end
    return { status = "needs_input", message = response.message }
  end
  if response.status ~= "ok" then
    return nil, ("unknown edit status: %s"):format(tostring(response.status))
  end
  local replacements, err = ordered_replacements(target, response)
  if not replacements then
    return nil, err
  end
  return { status = "ok", replacements = replacements }
end


local function display_result(replacements)
  if type(replacements) == "string" then
    return replacements
  end
  local parts = {}
  for _, replacement in ipairs(replacements or {}) do
    if type(replacement) == "table" and type(replacement.text) == "string" then
      parts[#parts + 1] = replacement.text
    elseif type(replacement) == "string" then
      parts[#parts + 1] = replacement
    else
      local ok, encoded = pcall(vim.json.encode, replacement)
      parts[#parts + 1] = ok and encoded or tostring(replacement)
    end
  end
  return table.concat(parts, "\n")
end

local function apply_failure(reason, replacements)
  return {
    applied = false,
    reason = reason,
    replacements = replacements,
    text = display_result(replacements),
  }
end

local function replace_mark(target, segment, start_row, start_col, end_row, end_col)
  delete_mark(target.bufnr, segment.mark)
  segment.mark = set_range_mark(target.bufnr, start_row, start_col, end_row, end_col)
  segment.boundary_start = boundary_at(target.bufnr, start_row, start_col)
  segment.boundary_end = boundary_at(target.bufnr, end_row, end_col)
end

local function replacement_end(start_row, start_col, text)
  local lines = split_text(text)
  if #lines == 1 then
    return start_row, start_col + #lines[1]
  end
  return start_row + #lines - 1, #lines[#lines]
end

local function rollback(bufnr)
  pcall(api.nvim_buf_call, bufnr, function()
    vim.cmd("silent undo")
  end)
end

function M.apply(target, response)
  local raw_response = type(response) == "string" and response or nil
  if raw_response then
    local decoded, decode_error = M.decode_result(target, raw_response)
    if not decoded then
      return apply_failure(decode_error, raw_response)
    end
    response = decoded
  elseif type(response) == "table" and response.status ~= nil then
    local decoded, decode_error = M.decode_result(target, response)
    if not decoded then
      local raw = response.replacements or response.message or response
      return apply_failure(decode_error, raw)
    end
    response = decoded
  end
  if type(response) == "table" and response.status == "needs_input" then
    return {
      applied = false,
      needs_input = true,
      reason = response.message,
      text = response.message,
      response = response,
    }
  end
  local replacements, replacement_error = ordered_replacements(target, response)
  if not replacements then
    local raw = type(response) == "table" and (response.replacements or response) or response
    return apply_failure(replacement_error, raw)
  end

  local valid, ranges_or_error = M.validate(target, true)
  if not valid then
    return apply_failure(ranges_or_error, replacements)
  end
  local ranges = ranges_or_error
  local operations = {}

  for index, segment in ipairs(target.segments) do
    local range = ranges[index]
    local replacement = replacements[index].text
    local operation = {
      index = index,
      segment = segment,
      range = range,
      replacement = replacement,
    }
    if target.style == "line" then
      operation.kind = "lines"
      operation.new_lines = replacement == "" and {} or split_text(replacement)
      operation.changed = replacement == "" or table.concat(
        api.nvim_buf_get_lines(target.bufnr, range.start_row, range.start_row + segment.line_count, true),
        "\n"
      ) ~= replacement
    else
      operation.kind = "text"
      local before = ""
      local after = ""
      if target.kind == "block" and (segment.source_text ~= "" or replacement ~= "") then
        before = string.rep(" ", segment.preserve_before or 0)
        after = string.rep(" ", segment.preserve_after or 0)
      end
      operation.inserted = before .. replacement .. after
      operation.replacement_col_offset = #before
      operation.changed = segment.source_text ~= operation.inserted
    end
    operations[#operations + 1] = operation
  end

  table.sort(operations, function(left, right)
    if left.range.start_row == right.range.start_row then
      return left.range.start_col > right.range.start_col
    end
    return left.range.start_row > right.range.start_row
  end)

  local applied = 0
  for _, operation in ipairs(operations) do
    if operation.changed then
      if applied > 0 then
        local joined = pcall(api.nvim_buf_call, target.bufnr, function()
          vim.cmd("undojoin")
        end)
        if not joined then
          rollback(target.bufnr)
          M.release(target)
          return apply_failure("could not join target edits into one undo step", replacements)
        end
      end

      local ok, err
      if operation.kind == "lines" then
        ok, err = pcall(
          api.nvim_buf_set_lines,
          target.bufnr,
          operation.range.start_row,
          operation.range.start_row + operation.segment.line_count,
          true,
          operation.new_lines
        )
      else
        ok, err = pcall(
          api.nvim_buf_set_text,
          target.bufnr,
          operation.range.start_row,
          operation.range.start_col,
          operation.range.end_row,
          operation.range.end_col,
          split_text(operation.inserted)
        )
      end
      if not ok then
        if applied > 0 then
          rollback(target.bufnr)
        end
        M.release(target)
        return apply_failure(("could not apply edit: %s"):format(err), replacements)
      end
      applied = applied + 1
    end

    local segment = operation.segment
    local start_row = operation.range.start_row
    local start_col = operation.range.start_col
    local end_row, end_col
    if operation.kind == "lines" then
      if operation.replacement == "" then
        local line_count = api.nvim_buf_line_count(target.bufnr)
        start_row = math.min(start_row, line_count - 1)
        start_col = 0
        end_row, end_col = start_row, start_col
        target.style = "text"
        segment.line_count = nil
      else
        segment.line_count = #operation.new_lines
        end_row = start_row + #operation.new_lines - 1
        end_col = #operation.new_lines[#operation.new_lines]
      end
    else
      start_col = start_col + (operation.replacement_col_offset or 0)
      end_row, end_col = replacement_end(start_row, start_col, operation.replacement)
    end

    replace_mark(target, segment, start_row, start_col, end_row, end_col)
    segment.text = operation.replacement
    segment.source_text = operation.replacement
    segment.preserve_before = 0
    segment.preserve_after = 0
    segment.start_virtual_offset = 0
    segment.end_virtual_offset = 0
    if target.kind == "block" then
      local line = api.nvim_buf_get_lines(target.bufnr, start_row, start_row + 1, true)[1] or ""
      local tabstop = option("tabstop", target.bufnr)
      segment.source_display_width = display_width(
        operation.replacement,
        screen_col(line, start_col, tabstop),
        tabstop
      )
    end
  end

  target.source_revision = api.nvim_buf_get_changedtick(target.bufnr)
  target.insertion = false
  if target.operation == nil or target.operation == "replace" then
    local previous = remembered[target.bufnr]
    if previous and previous ~= target then
      M.release(previous)
    end
    remembered[target.bufnr] = target
  end
  return {
    applied = true,
    target = target,
    replacements = replacements,
    text = display_result(replacements),
    changed = applied > 0,
  }
end

function M.to_envelope(target)
  local valid, ranges_or_error = M.validate(target, false)
  if not valid then
    return nil, ranges_or_error
  end
  local result = {}
  for index, segment in ipairs(target.segments) do
    local range = ranges_or_error[index]
    local start_boundary = boundary_at(target.bufnr, range.start_row, range.start_col)
    local end_boundary = boundary_at(target.bufnr, range.end_row, range.end_col)
    result[index] = {
      id = segment.id,
      selection = target.kind == "block" and "blockwise-row" or target.style,
      row_segment = target.kind == "block" and index - 1 or nil,
      coordinates = "zero-based UTF-8 bytes; end-exclusive",
      start = { range.start_row, range.start_col },
      ["end"] = { range.end_row, range.end_col },
      text = segment.text,
      boundary = {
        before = start_boundary.before,
        after = end_boundary.after,
        source_text = segment.source_text,
        start_virtual_offset = segment.start_virtual_offset or 0,
        end_virtual_offset = segment.end_virtual_offset or 0,
      },
    }
  end
  return result
end

function M.bounds(target)
  local valid, ranges_or_error = M.validate(target, false)
  if not valid then
    return nil, ranges_or_error
  end
  local first = ranges_or_error[1]
  local last = ranges_or_error[#ranges_or_error]
  return {
    start_row = first.start_row,
    start_col = first.start_col,
    end_row = last.end_row,
    end_col = last.end_col,
  }
end

function M.remember(target)
  local valid, err = M.validate(target, false)
  if not valid then
    return nil, err
  end
  local previous = remembered[target.bufnr]
  if previous and previous ~= target then
    M.release(previous)
  end
  remembered[target.bufnr] = target
  return target
end

function M.remembered(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()
  local target = remembered[bufnr]
  if not target then
    return nil, "no remembered target in this buffer"
  end
  local valid, err = M.validate(target, false)
  if not valid then
    remembered[bufnr] = nil
    M.release(target)
    return nil, err
  end
  return target
end

function M.forget(bufnr)
  local target = remembered[bufnr]
  remembered[bufnr] = nil
  if target then
    M.release(target)
  end
end

function M.highlight(target, group)
  M.clear_highlight(target)
  if not valid_buffer(target.bufnr) then
    return nil, "source buffer was deleted or unloaded"
  end
  group = group or "Visual"
  target.highlight_marks = {}
  for _, segment in ipairs(target.segments) do
    local range, err = resolve_segment(target, segment)
    if not range then
      M.clear_highlight(target)
      return nil, err
    end
    local opts
    if range.start_row == range.end_row and range.start_col == range.end_col then
      opts = {
        virt_text = { { "▏", group } },
        virt_text_pos = "inline",
        right_gravity = true,
      }
    else
      opts = {
        end_row = range.end_row,
        end_col = range.end_col,
        hl_group = group,
        hl_eol = target.style == "line",
        priority = 120,
      }
    end
    local ok, mark = pcall(api.nvim_buf_set_extmark, target.bufnr, ns, range.start_row, range.start_col, opts)
    if ok then
      target.highlight_marks[#target.highlight_marks + 1] = mark
    end
  end
  return true
end

function M.clear_highlight(target)
  if not target or not target.highlight_marks then
    return
  end
  for _, mark in ipairs(target.highlight_marks) do
    delete_mark(target.bufnr, mark)
  end
  target.highlight_marks = nil
end

function M.release(target)
  if not target then
    return
  end
  M.clear_highlight(target)
  for _, segment in ipairs(target.segments or {}) do
    delete_mark(target.bufnr, segment.mark)
    segment.mark = nil
  end
  if remembered[target.bufnr] == target then
    remembered[target.bufnr] = nil
  end
end

M.namespace = ns

return M
