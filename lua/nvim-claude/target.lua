local M = {}
local api = vim.api
local ns = api.nvim_create_namespace("nvim-claude-targets")
local next_target = 0

local function id()
  next_target = next_target + 1
  return "target-" .. next_target
end

local function line_at(buf, row)
  return api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
end

local function next_char_byte(line, col)
  if col >= #line then return #line end
  local char_index = vim.fn.charidx(line, col)
  local result = vim.fn.byteidx(line, char_index + 1)
  return result < 0 and #line or result
end

local function ordered(a_row, a_col, b_row, b_col)
  if a_row < b_row or (a_row == b_row and a_col <= b_col) then
    return a_row, a_col, b_row, b_col
  end
  return b_row, b_col, a_row, a_col
end

local function make_mark(buf, row, col, right_gravity)
  return api.nvim_buf_set_extmark(buf, ns, row, col, {
    right_gravity = right_gravity,
    strict = false,
  })
end

local function segment(buf, start_row, start_col, end_row, end_col, text, extra)
  local value = extra or {}
  value.id = id()
  value.start_mark = make_mark(buf, start_row, start_col, false)
  value.end_mark = make_mark(buf, end_row, end_col, true)
  value.start_row = start_row
  value.start_col = start_col
  value.end_row = end_row
  value.end_col = end_col
  value.original = api.nvim_buf_get_text(buf, start_row, start_col, end_row, end_col, {})
  value.original = table.concat(value.original, "\n")
  value.text = text == nil and value.original or text
  return value
end

local function char_selection(buf, a_row, a_col, b_row, b_col)
  local sr, sc, er, ec = ordered(a_row, a_col, b_row, b_col)
  ec = next_char_byte(line_at(buf, er), ec)
  return { segment(buf, sr, sc, er, ec) }
end

local function line_selection(buf, a_row, b_row)
  local sr, er = math.min(a_row, b_row), math.max(a_row, b_row)
  local count = api.nvim_buf_line_count(buf)
  if er + 1 < count then
    return { segment(buf, sr, 0, er + 1, 0) }
  end
  return { segment(buf, sr, 0, er, #line_at(buf, er)) }
end

local function char_cells(ch, column, tabstop)
  if ch == "\t" then return tabstop - (column % tabstop) end
  return math.max(1, vim.fn.strdisplaywidth(ch))
end

local function block_row_segment(buf, row, selected_start, selected_end)
  local line = line_at(buf, row)
  local tabstop = vim.bo[buf].tabstop
  local cells = 0
  local byte_start, byte_end = nil, nil
  local left_keep, right_keep = "", ""
  local selected = {}
  local chars = vim.fn.strchars(line)

  for index = 0, chars - 1 do
    local begin = vim.fn.byteidx(line, index)
    local finish = vim.fn.byteidx(line, index + 1)
    if finish < 0 then finish = #line end
    local ch = line:sub(begin + 1, finish)
    local width = char_cells(ch, cells, tabstop)
    local cell_end = cells + width
    if cell_end > selected_start and cells < selected_end then
      byte_start = byte_start or begin
      byte_end = finish
      local overlap_start = math.max(cells, selected_start)
      local overlap_end = math.min(cell_end, selected_end)
      if ch == "\t" then
        if overlap_start > cells then left_keep = string.rep(" ", overlap_start - cells) end
        table.insert(selected, string.rep(" ", math.max(0, overlap_end - overlap_start)))
        if overlap_end < cell_end then right_keep = string.rep(" ", cell_end - overlap_end) end
      else
        table.insert(selected, ch)
      end
    end
    cells = cell_end
  end

  if not byte_start then
    byte_start, byte_end = #line, #line
    if cells < selected_start then left_keep = string.rep(" ", selected_start - cells) end
    if selected_end > selected_start then table.insert(selected, string.rep(" ", selected_end - selected_start)) end
  end

  return segment(buf, row, byte_start, row, byte_end, table.concat(selected), {
    block = true,
    left_keep = left_keep,
    right_keep = right_keep,
  })
end

local function block_selection(buf, a_row, b_row, start_vcol, end_vcol)
  local segments = {}
  local first, last = math.min(a_row, b_row), math.max(a_row, b_row)
  local selected_start = math.min(start_vcol, end_vcol) - 1
  local selected_end = math.max(start_vcol, end_vcol)
  for row = first, last do
    table.insert(segments, block_row_segment(buf, row, selected_start, selected_end))
  end
  return segments
end

local function target(buf, kind, segments, visual_mode)
  return {
    buf = buf,
    kind = kind,
    visual_mode = visual_mode,
    segments = segments,
    changedtick = api.nvim_buf_get_changedtick(buf),
  }
end

function M.capture_visual(kind)
  local buf = api.nvim_get_current_buf()
  local mode = vim.fn.mode(1):sub(1, 1)
  local anchor = vim.fn.getpos("v")
  local cursor = vim.fn.getpos(".")
  local ar, ac = anchor[2] - 1, math.max(0, anchor[3] - 1)
  local cr, cc = cursor[2] - 1, math.max(0, cursor[3] - 1)
  local segments
  if mode == "V" then
    segments = line_selection(buf, ar, cr)
  elseif mode == "\022" then
    local av = vim.fn.virtcol("v")
    local cv = vim.fn.virtcol(".")
    segments = block_selection(buf, ar, cr, av, cv)
  else
    mode = "v"
    segments = char_selection(buf, ar, ac, cr, cc)
  end
  return target(buf, kind, segments, mode)
end

function M.capture_insert(insert_mode)
  local buf = api.nvim_get_current_buf()
  local cursor = api.nvim_win_get_cursor(0)
  local row, col = cursor[1] - 1, cursor[2]
  if not insert_mode then
    col = math.min(col, #line_at(buf, row))
  end
  return target(buf, "generate", { segment(buf, row, col, row, col, "") }, nil)
end

function M.valid(value)
  if not value or not api.nvim_buf_is_valid(value.buf) then return false, "source buffer no longer exists" end
  if not vim.bo[value.buf].modifiable then return false, "source buffer is not modifiable" end
  for _, item in ipairs(value.segments) do
    local start_pos = api.nvim_buf_get_extmark_by_id(value.buf, ns, item.start_mark, {})
    local end_pos = api.nvim_buf_get_extmark_by_id(value.buf, ns, item.end_mark, {})
    if #start_pos == 0 or #end_pos == 0 then return false, "target tracking was lost" end
    local current = table.concat(api.nvim_buf_get_text(value.buf, start_pos[1], start_pos[2], end_pos[1], end_pos[2], {}), "\n")
    if current ~= item.original then return false, "target content changed while Claude was working" end
  end
  return true
end

function M.envelope_targets(value)
  local result = {}
  for _, item in ipairs(value.segments) do
    local start_pos = api.nvim_buf_get_extmark_by_id(value.buf, ns, item.start_mark, {})
    local end_pos = api.nvim_buf_get_extmark_by_id(value.buf, ns, item.end_mark, {})
    table.insert(result, {
      id = item.id,
      coordinates = "zero-based UTF-8 bytes; end-exclusive",
      start = { start_pos[1], start_pos[2] },
      ["end"] = { end_pos[1], end_pos[2] },
      text = item.text,
    })
  end
  return result
end

function M.highlight_ranges(value)
  local result = {}
  if not value then return result end
  for _, item in ipairs(value.segments) do
    local start_pos = api.nvim_buf_get_extmark_by_id(value.buf, ns, item.start_mark, {})
    local end_pos = api.nvim_buf_get_extmark_by_id(value.buf, ns, item.end_mark, {})
    if #start_pos > 0 and #end_pos > 0 then
      table.insert(result, { start_pos[1], start_pos[2], end_pos[1], end_pos[2] })
    end
  end
  return result
end

local function replacement_map(value, replacements)
  local expected, mapped = {}, {}
  for _, item in ipairs(value.segments) do expected[item.id] = item end
  if type(replacements) ~= "table" or #replacements ~= #value.segments then
    return nil, "response must contain exactly one replacement for every target"
  end
  for _, replacement in ipairs(replacements) do
    if type(replacement) ~= "table" or type(replacement.id) ~= "string" or type(replacement.text) ~= "string" then
      return nil, "each replacement must contain string id and text fields"
    end
    if not expected[replacement.id] or mapped[replacement.id] then
      return nil, "response contains an unknown or duplicate target ID"
    end
    if expected[replacement.id].block and replacement.text:find("\n", 1, true) then
      return nil, "blockwise replacements cannot contain newlines"
    end
    mapped[replacement.id] = replacement.text
  end
  return mapped
end

function M.decode_result(value, raw)
  local ok, decoded = pcall(vim.json.decode, raw)
  if not ok or type(decoded) ~= "table" then return nil, "Claude returned malformed edit JSON" end
  if decoded.status == "needs_input" and type(decoded.message) == "string" then
    return { needs_input = decoded.message }
  end
  if decoded.status ~= "ok" then return nil, "Claude returned an unknown edit status" end
  local mapped, err = replacement_map(value, decoded.replacements)
  if not mapped then return nil, err end
  return { replacements = mapped }
end

local function end_position(row, col, text)
  local lines = vim.split(text, "\n", { plain = true })
  if #lines == 1 then return row, col + #lines[1] end
  return row + #lines - 1, #lines[#lines]
end

function M.apply(value, replacements, normalize)
  local ok, reason = M.valid(value)
  if not ok then return false, reason end
  local ordered_segments = vim.deepcopy(value.segments)
  table.sort(ordered_segments, function(a, b)
    if a.start_row == b.start_row then return a.start_col > b.start_col end
    return a.start_row > b.start_row
  end)
  local applied = {}
  for index, item in ipairs(ordered_segments) do
    local start_pos = api.nvim_buf_get_extmark_by_id(value.buf, ns, item.start_mark, {})
    local end_pos = api.nvim_buf_get_extmark_by_id(value.buf, ns, item.end_mark, {})
    local target_text = normalize(replacements[item.id])
    local prefix = item.block and item.left_keep or ""
    local suffix = item.block and item.right_keep or ""
    local replacement = prefix .. target_text .. suffix
    if index > 1 then pcall(vim.cmd, "undojoin") end
    api.nvim_buf_set_text(value.buf, start_pos[1], start_pos[2], end_pos[1], end_pos[2], vim.split(replacement, "\n", { plain = true }))
    applied[item.id] = {
      row = start_pos[1],
      col = start_pos[2] + #prefix,
      text = target_text,
    }
  end
  for _, item in ipairs(value.segments) do
    local detail = applied[item.id]
    api.nvim_buf_del_extmark(value.buf, ns, item.start_mark)
    api.nvim_buf_del_extmark(value.buf, ns, item.end_mark)
    local er, ec = end_position(detail.row, detail.col, detail.text)
    item.start_mark = make_mark(value.buf, detail.row, detail.col, false)
    item.end_mark = make_mark(value.buf, er, ec, true)
    item.original = detail.text
    item.text = detail.text
    item.start_row, item.start_col, item.end_row, item.end_col = detail.row, detail.col, er, ec
    item.left_keep, item.right_keep = "", ""
  end
  value.changedtick = api.nvim_buf_get_changedtick(value.buf)
  return true
end

function M.dispose(value)
  if not value or not api.nvim_buf_is_valid(value.buf) then return end
  for _, item in ipairs(value.segments) do
    api.nvim_buf_del_extmark(value.buf, ns, item.start_mark)
    api.nvim_buf_del_extmark(value.buf, ns, item.end_mark)
  end
end

return M
