local M = {}
local ns = vim.api.nvim_create_namespace("nvim-claude-targets")
local remembered = {}
local selected_ask = nil
local serial = 0

local function ordered(a, b)
  if a[2] > b[2] or (a[2] == b[2] and a[3] > b[3]) then return b, a end
  return a, b
end

local function next_col(line, byte_col)
  if byte_col >= #line then return #line end
  local first = line:byte(byte_col + 1)
  if not first then return #line end
  local width = first < 0x80 and 1 or first < 0xE0 and 2 or first < 0xF0 and 3 or 4
  return math.min(byte_col + width, #line)
end

local function text(buf, sr, sc, er, ec)
  return table.concat(vim.api.nvim_buf_get_text(buf, sr, sc, er, ec, {}), "\n")
end

local function display_width(character, column)
  if character == "\t" then return vim.bo.tabstop - (column % vim.bo.tabstop) end
  return math.max(vim.fn.strdisplaywidth(character), 1)
end

local function materialize_boundaries(line, start_cell, end_cell)
  local output, cells, bytes = {}, 0, 0
  local start_byte, end_byte
  local count = vim.fn.strchars(line)
  for index = 0, count - 1 do
    local character = vim.fn.strcharpart(line, index, 1)
    local width = display_width(character, cells)
    local partial = (start_cell > cells and start_cell < cells + width) or (end_cell > cells and end_cell < cells + width)
    local rendered = partial and string.rep(" ", width) or character
    if start_cell == cells then start_byte = bytes end
    if end_cell == cells then end_byte = bytes end
    output[#output + 1] = rendered
    cells, bytes = cells + width, bytes + #rendered
  end
  if cells < end_cell then
    local padding = string.rep(" ", end_cell - cells)
    output[#output + 1] = padding
    bytes = bytes + #padding
    cells = end_cell
  end
  start_byte = start_byte or math.min(start_cell, bytes)
  end_byte = end_byte or bytes
  return table.concat(output), start_byte, end_byte
end

local function mark_segment(buf, segment)
  segment.start_mark = vim.api.nvim_buf_set_extmark(buf, ns, segment.start_row, segment.start_col, {
    right_gravity = false,
    end_row = segment.end_row,
    end_col = segment.end_col,
    end_right_gravity = true,
    hl_group = "Visual",
  })
end

local function visual_segments(buf)
  local mode = vim.fn.mode(1)
  local active = mode == "v" or mode == "V" or mode:byte() == 22
  local first, last = active and vim.fn.getpos("v") or vim.fn.getpos("'<"), active and vim.fn.getpos(".") or vim.fn.getpos("'>")
  first, last = ordered(first, last)
  local kind = active and mode:sub(1, 1) or vim.fn.visualmode()
  local segments = {}
  if kind == "V" then
    segments[1] = { start_row = first[2] - 1, start_col = 0, end_row = last[2], end_col = 0 }
  elseif kind == "\022" then
    local ok, positions = pcall(vim.fn.getregionpos, first, last, { type = kind, exclusive = false, eol = true })
    local text_ok, selected = pcall(vim.fn.getregion, first, last, { type = kind, exclusive = false })
    assert(ok and text_ok and #positions > 0, "unable to capture block selection")
    for index, pair in ipairs(positions) do
      local a, b = pair[1], pair[2]
      local row = a[2] - 1
      local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
      local start_col = math.max(a[3] - 1, 0)
      local end_col = next_col(line, math.max(b[3] - 1, start_col))
      local start_cell = math.max(vim.fn.virtcol({ a[2], math.max(a[3], 1) }) - 1 + a[4], 0)
      local end_cell = b[4] > 0 and (vim.fn.virtcol({ b[2], math.max(b[3], 1) }) - 1 + b[4]) or (vim.fn.virtcol({ b[2], math.max(b[3], 1) }) - 1 + vim.fn.strdisplaywidth(line:sub(math.max(b[3], 1), end_col)))
      segments[index] = {
        start_row = row, start_col = start_col, end_row = row, end_col = end_col,
        block = true, partial_cell = a[4] > 0 or b[4] > 0, start_cell = start_cell,
        end_cell = end_cell, original_line = line, original = selected[index],
      }
    end
  else
    local start_row, start_col = first[2] - 1, first[3] - 1
    local end_row, end_col = last[2] - 1, last[3] - 1
    if vim.o.selection ~= "exclusive" then
      local line = vim.api.nvim_buf_get_lines(buf, end_row, end_row + 1, false)[1] or ""
      end_col = next_col(line, end_col)
    end
    segments[1] = { start_row = start_row, start_col = start_col, end_row = end_row, end_col = end_col }
  end
  return segments, kind
end

function M.capture(operation, use_visual)
  local buf = vim.api.nvim_get_current_buf()
  serial = serial + 1
  local target = { id = serial, operation = operation, buf = buf, win = vim.api.nvim_get_current_win(), tick = vim.api.nvim_buf_get_changedtick(buf), segments = {} }
  if operation == "generate" then
    local cursor = vim.api.nvim_win_get_cursor(target.win)
    local row, col = cursor[1] - 1, cursor[2]
    target.segments[1] = { start_row = row, start_col = col, end_row = row, end_col = col, original = "" }
  elseif use_visual then
    target.segments, target.visual_kind = visual_segments(buf)
  else
    local old = remembered[buf]
    if not old or not M.valid(old) then return nil, "Select text first; no valid remembered target exists." end
    target.segments = vim.deepcopy(old.segments)
    for _, segment in ipairs(target.segments) do segment.start_mark = nil end
    target.visual_kind = old.visual_kind
  end
  for index, segment in ipairs(target.segments) do
    segment.id = "target-" .. tostring(index - 1)
    segment.original = segment.original or text(buf, segment.start_row, segment.start_col, segment.end_row, segment.end_col)
    mark_segment(buf, segment)
  end
  return target
end

function M.valid(target)
  if not target or not vim.api.nvim_buf_is_valid(target.buf) then return false end
  for _, segment in ipairs(target.segments) do
    local pos = vim.api.nvim_buf_get_extmark_by_id(target.buf, ns, segment.start_mark, { details = true })
    if #pos == 0 then return false end
    local details = pos[3]
    if segment.original_line then
      local line = vim.api.nvim_buf_get_lines(target.buf, pos[1], pos[1] + 1, false)[1]
      if line ~= segment.original_line then return false end
    elseif text(target.buf, pos[1], pos[2], details.end_row, details.end_col) ~= segment.original then return false end
  end
  return true
end

function M.payload(target)
  local values = {}
  for _, segment in ipairs(target.segments) do
    local pos = vim.api.nvim_buf_get_extmark_by_id(target.buf, ns, segment.start_mark, { details = true })
    local details = pos[3]
    values[#values + 1] = {
      id = segment.id,
      coordinates = "zero-based UTF-8 bytes; end-exclusive",
      start = { pos[1], pos[2] },
      ["end"] = { details.end_row, details.end_col },
      text = segment.original,
      block = segment.block or nil,
    }
  end
  return values
end

function M.apply(target, replacements)
  if not M.valid(target) then return false, "The target changed while Claude was responding. The result was not applied." end
  if not vim.bo[target.buf].modifiable then return false, "The source buffer is not modifiable. The result was not applied." end
  local by_id = {}
  for _, replacement in ipairs(replacements) do by_id[replacement.id] = replacement.text end
  local applied = {}
  for index = #target.segments, 1, -1 do
    local segment = target.segments[index]
    local pos = vim.api.nvim_buf_get_extmark_by_id(target.buf, ns, segment.start_mark, { details = true })
    local details = pos[3]
    local replacement = by_id[segment.id]
    if segment.block and replacement:find("\n", 1, true) then return false, "A blockwise replacement contained a newline." end
    if #applied > 0 then pcall(vim.cmd, "undojoin") end
    local row, col = pos[1], pos[2]
    if segment.partial_cell then
      local rendered, start_byte, end_byte = materialize_boundaries(segment.original_line, segment.start_cell, segment.end_cell)
      local changed = rendered:sub(1, start_byte) .. replacement .. rendered:sub(end_byte + 1)
      vim.api.nvim_buf_set_lines(target.buf, row, row + 1, false, { changed })
      col = start_byte
    else
      local lines = vim.split(replacement, "\n", { plain = true })
      vim.api.nvim_buf_set_text(target.buf, row, col, details.end_row, details.end_col, lines)
    end
    applied[#applied + 1] = { replacement = replacement, row = row, col = col }
  end
  local fresh = { buf = target.buf, visual_kind = target.visual_kind, segments = {} }
  for index, item in ipairs(vim.fn.reverse(applied)) do
    local lines = vim.split(item.replacement, "\n", { plain = true })
    local er = item.row + #lines - 1
    local ec = #lines == 1 and item.col + #lines[1] or #lines[#lines]
    local segment = { id = "target-" .. tostring(index - 1), start_row = item.row, start_col = item.col, end_row = er, end_col = ec, original = item.replacement, block = target.segments[index].block }
    mark_segment(target.buf, segment)
    fresh.segments[index] = segment
  end
  if target.operation == "replace" then remembered[target.buf] = fresh end
  selected_ask = nil
  return true
end

function M.remember_ask(target) selected_ask = target end
function M.previous_ask(buf)
  if selected_ask and selected_ask.buf == buf and M.valid(selected_ask) then return selected_ask end
  selected_ask = nil
  return nil
end
function M.break_ask_chain() selected_ask = nil end

function M.clear_highlight(target)
  if not target or not vim.api.nvim_buf_is_valid(target.buf) then return end
  for _, segment in ipairs(target.segments) do
    local pos = vim.api.nvim_buf_get_extmark_by_id(target.buf, ns, segment.start_mark, { details = true })
    if #pos > 0 then
      local details = pos[3]
      pcall(vim.api.nvim_buf_set_extmark, target.buf, ns, pos[1], pos[2], {
        id = segment.start_mark, end_row = details.end_row, end_col = details.end_col,
        right_gravity = false, end_right_gravity = true,
      })
    end
  end
end

return M
