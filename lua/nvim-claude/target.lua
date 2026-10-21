local util = require("nvim-claude.util")

local M = {}
local ns = vim.api.nvim_create_namespace("nvim-claude-targets")
local remembered_replace = {}
local remembered_ask = {}
local last_action = {}

local function line_at(buf, row)
  return (vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or "")
end

local function char_width(char, virtual_col, tabstop)
  if char == "\t" then
    return tabstop - (virtual_col % tabstop)
  end
  return math.max(1, vim.fn.strdisplaywidth(char))
end

local function virtual_segment(line, left, right, tabstop)
  local byte = 0
  local virtual = 0
  local first_byte, last_byte
  local selected = {}
  local prefix, suffix = "", ""
  local char_index = 0

  while byte < #line do
    local char = vim.fn.strcharpart(line, char_index, 1)
    local bytes = #char
    local width = char_width(char, virtual, tabstop)
    local char_end = virtual + width
    if char_end > left and virtual < right then
      first_byte = first_byte or byte
      last_byte = byte + bytes
      local overlap_start = math.max(left, virtual)
      local overlap_end = math.min(right, char_end)
      if char == "\t" then
        if overlap_start > virtual and first_byte == byte then
          prefix = string.rep(" ", overlap_start - virtual)
        end
        table.insert(selected, string.rep(" ", overlap_end - overlap_start))
        if overlap_end < char_end then
          suffix = string.rep(" ", char_end - overlap_end)
        end
      else
        table.insert(selected, char)
      end
    end
    byte = byte + bytes
    virtual = char_end
    char_index = char_index + 1
  end

  if virtual < left then
    first_byte, last_byte = #line, #line
    prefix = string.rep(" ", left - virtual)
  elseif not first_byte then
    first_byte, last_byte = #line, #line
  end
  if virtual < right then
    table.insert(selected, string.rep(" ", right - math.max(left, virtual)))
  end

  return {
    start_col = first_byte,
    end_col = last_byte,
    text = table.concat(selected),
    raw = line:sub(first_byte + 1, last_byte),
    apply_prefix = prefix,
    apply_suffix = suffix,
  }
end

local function mark_segment(buf, segment, highlight)
  segment.mark = vim.api.nvim_buf_set_extmark(buf, ns, segment.start_row, segment.start_col, {
    end_row = segment.end_row,
    end_col = segment.end_col,
    right_gravity = false,
    end_right_gravity = true,
    hl_group = highlight and "Visual" or nil,
    strict = false,
  })
end

local function make_target(buf, kind, segments, operation)
  local target = {
    buffer = buf,
    kind = kind,
    segments = segments,
    operation = operation,
    changedtick = vim.api.nvim_buf_get_changedtick(buf),
    origin_win = vim.api.nvim_get_current_win(),
  }
  for _, segment in ipairs(segments) do
    mark_segment(buf, segment, true)
  end
  return target
end

local function visual_region(buf, mode)
  local anchor = vim.fn.getpos("v")
  local cursor = vim.fn.getcurpos()
  local a = { anchor[2] - 1, anchor[3] - 1, anchor[4] or 0 }
  local c = { cursor[2] - 1, cursor[3] - 1, cursor[4] or 0 }
  local region = vim.fn.getregionpos(anchor, cursor, {
    type = mode,
    exclusive = vim.o.selection == "exclusive",
  })
  local rows = {}
  for _, pair in ipairs(region) do
    table.insert(rows, pair[1][2] - 1)
  end
  return region, rows, a, c
end

function M.capture_visual(operation)
  local buf = vim.api.nvim_get_current_buf()
  local mode = vim.fn.mode(1):sub(1, 1)
  if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
    return nil, "A Visual selection is required"
  end
  local region, rows, anchor, cursor = visual_region(buf, mode)
  if #rows == 0 then
    return nil, "The Visual selection is empty"
  end

  if mode == "\22" then
    local anchor_virtual = vim.fn.virtcol({ anchor[1] + 1, anchor[2] + 1, anchor[3] })
    local cursor_virtual = vim.fn.virtcol({ cursor[1] + 1, cursor[2] + 1, cursor[3] })
    local left = math.min(anchor_virtual, cursor_virtual) - 1
    local right = math.max(anchor_virtual, cursor_virtual)
    if vim.o.selection == "exclusive" then
      if cursor_virtual >= anchor_virtual then
        right = math.max(left, right - 1)
      else
        left = math.min(right, left + 1)
      end
    end
    local segments = {}
    local tabstop = vim.bo[buf].tabstop
    for index, row in ipairs(rows) do
      local part = virtual_segment(line_at(buf, row), left, right, tabstop)
      part.id = "target-" .. (index - 1)
      part.start_row, part.end_row = row, row
      table.insert(segments, part)
    end
    return make_target(buf, "block", segments, operation)
  end

  if mode == "V" then
    local start_row, end_row = rows[1], rows[#rows]
    local lines = vim.api.nvim_buf_get_lines(buf, start_row, end_row + 1, false)
    return make_target(buf, "line", {
      {
        id = "target-0",
        start_row = start_row,
        start_col = 0,
        end_row = end_row,
        end_col = #line_at(buf, end_row),
        text = table.concat(lines, "\n"),
        raw = table.concat(lines, "\n"),
      },
    }, operation)
  end

  local first, last = rows[1], rows[#rows]
  local start_pos = region[1][1]
  local end_pos = region[#region][2]
  local start_col = start_pos[3] - 1
  local last_line = line_at(buf, last)
  local end_start = math.min(end_pos[3] - 1, #last_line)
  local end_char = vim.fn.strcharpart(last_line:sub(end_start + 1), 0, 1)
  local end_col = math.min(#last_line, end_start + #end_char)
  local text = table.concat(vim.api.nvim_buf_get_text(buf, first, start_col, last, end_col, {}), "\n")
  return make_target(buf, "char", {
    {
      id = "target-0",
      start_row = first,
      start_col = start_col,
      end_row = last,
      end_col = end_col,
      text = text,
      raw = text,
    },
  }, operation)
end

function M.capture_insert(mode)
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row, col = cursor[1] - 1, cursor[2]
  if mode == "i" then
    col = math.min(col, #line_at(buf, row))
  end
  local line = line_at(buf, row)
  local segment = {
    id = "target-0",
    start_row = row,
    start_col = col,
    end_row = row,
    end_col = col,
    text = "",
    raw = "",
    boundary_before = line:sub(math.max(1, col - 31), col),
    boundary_after = line:sub(col + 1, col + 32),
  }
  return make_target(buf, "insert", { segment }, "generate")
end

local function current_range(target, segment)
  local details = vim.api.nvim_buf_get_extmark_by_id(target.buffer, ns, segment.mark, { details = true })
  if not details or #details == 0 then
    return nil
  end
  return details[1], details[2], details[3].end_row, details[3].end_col
end

function M.validate(target)
  if not target or not vim.api.nvim_buf_is_valid(target.buffer) then
    return nil, "The source buffer no longer exists"
  end
  if not vim.bo[target.buffer].modifiable then
    return nil, "The source buffer is not modifiable"
  end
  local ranges = {}
  for _, segment in ipairs(target.segments) do
    local sr, sc, er, ec = current_range(target, segment)
    if not sr then
      return nil, "The target no longer exists"
    end
    local current
    if target.kind == "line" then
      current = table.concat(vim.api.nvim_buf_get_lines(target.buffer, sr, er + 1, false), "\n")
    else
      current = table.concat(vim.api.nvim_buf_get_text(target.buffer, sr, sc, er, ec, {}), "\n")
    end
    if current ~= segment.raw then
      return nil, "The target changed while Claude was working"
    end
    if target.kind == "insert" then
      local line = line_at(target.buffer, sr)
      local before = line:sub(math.max(1, sc - 31), sc)
      local after = line:sub(sc + 1, sc + 32)
      if before ~= segment.boundary_before or after ~= segment.boundary_after then
        return nil, "The insertion boundary changed while Claude was working"
      end
    end
    table.insert(ranges, { sr, sc, er, ec })
  end
  return ranges
end

function M.clone(target, operation)
  local ranges, err = M.validate(target)
  if not ranges then
    return nil, err
  end
  local segments = {}
  for index, old in ipairs(target.segments) do
    local range = ranges[index]
    local segment = vim.deepcopy(old)
    segment.mark = nil
    segment.start_row, segment.start_col = range[1], range[2]
    segment.end_row, segment.end_col = range[3], range[4]
    table.insert(segments, segment)
  end
  return make_target(target.buffer, target.kind, segments, operation)
end

function M.request_targets(target)
  local ranges, err = M.validate(target)
  if not ranges then
    return nil, err
  end
  local result = {}
  for index, segment in ipairs(target.segments) do
    local range = ranges[index]
    local item = {
      id = segment.id,
      coordinates = "zero-based UTF-8 bytes; end-exclusive",
      start = { range[1], range[2] },
      ["end"] = { range[3], range[4] },
      text = segment.text,
    }
    if target.kind == "insert" then
      item.boundary_before = segment.boundary_before
      item.boundary_after = segment.boundary_after
    end
    table.insert(result, item)
  end
  return result
end

function M.clear(target)
  if not target or not vim.api.nvim_buf_is_valid(target.buffer) then
    return
  end
  for _, segment in ipairs(target.segments) do
    pcall(vim.api.nvim_buf_del_extmark, target.buffer, ns, segment.mark)
  end
end

function M.dim(target)
  if not target or not vim.api.nvim_buf_is_valid(target.buffer) then
    return
  end
  for _, segment in ipairs(target.segments) do
    local sr, sc, er, ec = current_range(target, segment)
    if sr then
      segment.mark = vim.api.nvim_buf_set_extmark(target.buffer, ns, sr, sc, {
        id = segment.mark,
        end_row = er,
        end_col = ec,
        right_gravity = false,
        end_right_gravity = true,
        strict = false,
      })
    end
  end
end

function M.status(target, message)
  if not target or not target.segments[1] or not vim.api.nvim_buf_is_valid(target.buffer) then
    return
  end
  local segment = target.segments[1]
  local sr, sc, er, ec = current_range(target, segment)
  if not sr then
    return
  end
  segment.mark = vim.api.nvim_buf_set_extmark(target.buffer, ns, sr, sc, {
    id = segment.mark,
    end_row = er,
    end_col = ec,
    right_gravity = false,
    end_right_gravity = true,
    hl_group = "Visual",
    virt_text = { { " Claude: " .. message .. " ", "DiagnosticInfo" } },
    virt_text_pos = "eol",
    strict = false,
  })
end

function M.apply(target, replacements)
  local ranges, err = M.validate(target)
  if not ranges then
    return nil, err
  end
  local by_id = {}
  for _, replacement in ipairs(replacements) do
    by_id[replacement.id] = replacement.text
  end
  local created = {}
  local resulting_kind = target.kind
  local order = {}
  for index = #target.segments, 1, -1 do
    table.insert(order, index)
  end

  local ok, apply_err = pcall(vim.api.nvim_buf_call, target.buffer, function()
    local first = true
    for _, index in ipairs(order) do
      local segment = target.segments[index]
      local range = ranges[index]
      local replacement = by_id[segment.id]
      if not first then
        pcall(vim.cmd, "undojoin")
      end
      first = false
      if target.kind == "line" then
        if replacement == "" then
          vim.api.nvim_buf_set_lines(target.buffer, range[1], range[3] + 1, false, {})
          created[index] = { range[1], 0, range[1], 0, "" }
          resulting_kind = "char"
        else
          local lines = util.split_lines(replacement)
          vim.api.nvim_buf_set_lines(target.buffer, range[1], range[3] + 1, false, lines)
          created[index] = { range[1], 0, range[1] + #lines - 1, #lines[#lines], replacement }
        end
      else
        local prefix = target.kind == "block" and (segment.apply_prefix or "") or ""
        local suffix = target.kind == "block" and (segment.apply_suffix or "") or ""
        local applied = prefix .. replacement .. suffix
        local lines = util.split_lines(applied)
        vim.api.nvim_buf_set_text(target.buffer, range[1], range[2], range[3], range[4], lines)
        if target.kind == "block" then
          created[index] = {
            range[1], range[2] + #prefix, range[1], range[2] + #prefix + #replacement, replacement,
          }
        else
          local end_row = range[1] + #lines - 1
          local end_col = #lines == 1 and range[2] + #lines[1] or #lines[#lines]
          created[index] = { range[1], range[2], end_row, end_col, applied }
        end
      end
    end
  end)
  if not ok then
    return nil, tostring(apply_err)
  end

  M.clear(target)
  local segments = {}
  for index, old in ipairs(target.segments) do
    local made = created[index]
    local replacement = by_id[old.id]
    local raw = made[5]
    table.insert(segments, {
      id = old.id,
      start_row = made[1], start_col = made[2], end_row = made[3], end_col = made[4],
      text = replacement, raw = raw,
      apply_prefix = target.kind == "block" and "" or nil,
      apply_suffix = target.kind == "block" and "" or nil,
    })
  end
  return make_target(target.buffer, resulting_kind, segments, target.operation)
end

function M.remember_replace(target)
  local old = remembered_replace[target.buffer]
  if old and old ~= target then
    M.clear(old)
  end
  remembered_replace[target.buffer] = target
  last_action[target.buffer] = "replace"
end

function M.remember_ask(target)
  local old = remembered_ask[target.buffer]
  if old and old ~= target then
    M.clear(old)
  end
  remembered_ask[target.buffer] = target
  last_action[target.buffer] = "selected_ask"
end

function M.previous_replace(buf)
  local target = remembered_replace[buf]
  if not target then
    return nil, "Select text before using replacement"
  end
  return M.clone(target, "replace")
end

function M.previous_ask(buf, explicit)
  if not explicit and last_action[buf] ~= "selected_ask" then
    return nil
  end
  local target = remembered_ask[buf]
  if not target then
    return nil, explicit and "There is no previous selected-ask target" or nil
  end
  return M.clone(target, "ask")
end

function M.content_action(buf, action)
  last_action[buf] = action
end

function M.invalidate_baselines_state()
  remembered_ask = {}
  last_action = {}
end

return M
