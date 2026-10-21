local M = {}
local api = vim.api
local ns = api.nvim_create_namespace("nvim-claude-targets")
local buffers = {}
local next_id = 0
local block_mode = string.char(22)

local function copy(p)
  return { p[1], p[2] }
end

local function compare(a, b)
  if a[1] ~= b[1] then
    return a[1] < b[1] and -1 or 1
  end
  return a[2] == b[2] and 0 or (a[2] < b[2] and -1 or 1)
end

local function line(buf, row)
  return api.nvim_buf_get_lines(buf, row, row + 1, true)[1] or ""
end

-- byteidx includes composing characters, matching native Visual selection.
local function char_end(text, col)
  if col >= #text then
    return #text
  end
  local size = vim.fn.byteidx(text:sub(col + 1), 1)
  return col + (size < 0 and #text - col or size)
end

local function boundary(text, col)
  col = math.max(0, math.min(col, #text))
  while col > 0 and col < #text do
    local byte = text:byte(col + 1)
    if byte < 128 or byte >= 192 then
      break
    end
    col = col - 1
  end
  return col
end

local function read_text(buf, first, last)
  return table.concat(api.nvim_buf_get_text(buf, first[1], first[2], last[1], last[2], {}), "\n")
end

local function surroundings(buf, first, last)
  local sr = math.max(0, first[1] - 1)
  local er = math.min(api.nvim_buf_line_count(buf) - 1, last[1] + 1)
  local before = read_text(buf, { sr, 0 }, first)
  local after = read_text(buf, last, { er, #line(buf, er) })
  if #before > 256 then
    before = before:sub(boundary(before, #before - 256) + 1)
  end
  if #after > 256 then
    after = after:sub(1, boundary(after, 256))
  end
  return before, after
end

local function guard(buf, p)
  local before, after = surroundings(buf, p, p)
  -- The neighboring character, including a newline, identifies an empty boundary.
  local left = vim.fn.strcharpart(before, math.max(0, vim.fn.strchars(before, 1) - 1), 1, 1)
  local right = vim.fn.strcharpart(after, 0, 1, 1)
  return left, right
end

local function invalidate(target, reason)
  target.invalid = reason or "The target was changed while the request was running"
end

local function shifted(p, start, old_end, new_end, right)
  local at_start = compare(p, start)
  if at_start < 0 or (at_start == 0 and not right) then
    return p
  end
  if compare(p, old_end) < 0 then
    return copy(new_end)
  end
  if p[1] == old_end[1] then
    return { new_end[1], new_end[2] + p[2] - old_end[2] }
  end
  return { new_end[1] + p[1] - old_end[1], p[2] }
end

local function observe(buf)
  if buffers[buf] then
    return buffers[buf]
  end
  local registry = setmetatable({}, { __mode = "k" })
  buffers[buf] = registry
  local function dead(reason)
    for target in pairs(registry) do
      invalidate(target, reason)
    end
  end
  local attached = api.nvim_buf_attach(buf, false, {
    on_bytes = function(_, _, _, row, col, _, old_rows, old_col, _, new_rows, new_col)
      local first = { row, col }
      local old_end = { row + old_rows, old_rows == 0 and col + old_col or old_col }
      local new_end = { row + new_rows, new_rows == 0 and col + new_col or new_col }
      local insertion = compare(first, old_end) == 0
      for target in pairs(registry) do
        if not target.invalid and not target.applying and not target.disposed then
          for _, segment in ipairs(target.segments) do
            local s, e = segment.first, segment.last
            local empty = compare(s, e) == 0
            local intersects
            if empty then
              intersects = compare(first, s) <= 0 and compare(old_end, s) >= 0
            elseif insertion then
              intersects = compare(first, s) > 0 and compare(first, e) < 0
            else
              intersects = compare(first, e) < 0 and compare(old_end, s) > 0
            end
            if intersects then
              invalidate(target)
              break
            end
            segment.first = shifted(s, first, old_end, new_end, true)
            segment.last = shifted(e, first, old_end, new_end, empty)
          end
        end
      end
    end,
    on_reload = function()
      dead("The source buffer was reloaded")
    end,
    on_detach = function()
      dead("The source buffer was unloaded or deleted")
      buffers[buf] = nil
    end,
  })
  if not attached then
    buffers[buf] = nil
    return nil
  end
  return registry
end

local function set_marks(target, segment)
  local empty = compare(segment.first, segment.last) == 0
  segment.start_mark = api.nvim_buf_set_extmark(target.buf, ns, segment.first[1], segment.first[2], {
    id = segment.start_mark,
    right_gravity = true,
    undo_restore = false,
  })
  segment.end_mark = api.nvim_buf_set_extmark(target.buf, ns, segment.last[1], segment.last[2], {
    id = segment.end_mark,
    right_gravity = empty,
    undo_restore = false,
  })
end

local function context_call(target, fn)
  if target.win and api.nvim_win_is_valid(target.win) and api.nvim_win_get_buf(target.win) == target.buf then
    return api.nvim_win_call(target.win, fn)
  end
  return api.nvim_buf_call(target.buf, fn)
end

local function native_position(buf, p)
  return { buf, p[1] + 1, p[2] + 1, p[3] or 0 }
end

local function segment_from_region(buf, pair, selected, is_block)
  local a, b = pair[1], pair[2]
  local first_line = line(buf, a[2] - 1)
  local last_line = line(buf, b[2] - 1)
  local first_col = boundary(first_line, math.max(0, a[3] - 1))
  local last_col = boundary(last_line, math.max(0, b[3] - 1))
  local prefix, suffix = "", ""
  if (a[4] or 0) > 0 then
    prefix = string.rep(" ", a[4])
  end
  local last_end = char_end(last_line, last_col)
  if (b[4] or 0) > 0 and last_col < #last_line then
    local screen_col = vim.fn.strdisplaywidth(last_line:sub(1, last_col))
    local width = vim.fn.strdisplaywidth(last_line:sub(last_col + 1, last_end), screen_col)
    suffix = string.rep(" ", math.max(0, width - b[4]))
  end
  return {
    first = { a[2] - 1, first_col },
    last = { b[2] - 1, last_end },
    text = selected,
    prefix = prefix,
    suffix = suffix,
    virtual_start_offset = a[4] or 0,
    virtual_end_offset = b[4] or 0,
    block = is_block,
  }
end

---Capture before opening any float. Explicit positions are zero-based byte positions.
---Omitted positions use live getpos('v')/getpos('.') including virtual offsets.
function M.capture(buf, mode, startpos, endpos)
  buf = buf == 0 and api.nvim_get_current_buf() or buf
  if not api.nvim_buf_is_valid(buf) or not api.nvim_buf_is_loaded(buf) then
    return nil, "The source buffer is not loaded"
  end
  local target = { buf = buf, win = api.nvim_get_current_win(), segments = {}, mode = mode }
  local ok, err = pcall(function()
    context_call(target, function()
      if mode == "generate" then
        local p = startpos or api.nvim_win_get_cursor(0)
        if not startpos then
          p = { p[1] - 1, p[2] }
        end
        if p[1] < 0 or p[1] >= api.nvim_buf_line_count(buf) then
          error("The insertion row is outside the source buffer")
        end
        local point = { p[1], boundary(line(buf, p[1]), p[2]) }
        target.segments[1] = { first = point, last = copy(point), text = "", prefix = "", suffix = "", block = false }
      else
        if mode ~= "v" and mode ~= "V" and mode ~= block_mode then
          error("Unsupported Visual selection mode")
        end
        if vim.fn.exists("*getregionpos") ~= 1 then
          error("nvim-claude requires Neovim with getregion() and getregionpos()")
        end
        local a = startpos and native_position(buf, startpos) or vim.fn.getpos("v")
        local b = endpos and native_position(buf, endpos) or vim.fn.getpos(".")
        a[1], b[1] = buf, buf
        local opts = { type = mode, exclusive = vim.o.selection == "exclusive" }
        local selected = vim.fn.getregion(a, b, opts)
        local positions = vim.fn.getregionpos(a, b, vim.tbl_extend("force", opts, { eol = true }))
        if #positions == 0 then
          error("There is no Visual selection to capture")
        end
        if mode == block_mode then
          for i, pair in ipairs(positions) do
            target.segments[i] = segment_from_region(buf, pair, selected[i] or "", true)
          end
        elseif mode == "V" then
          local first_row = positions[1][1][2] - 1
          local last_row = positions[#positions][2][2] - 1
          target.segments[1] = {
            first = { first_row, 0 }, last = { last_row, #line(buf, last_row) },
            text = table.concat(selected, "\n"), prefix = "", suffix = "", block = false,
          }
        else
          local pair = { positions[1][1], positions[#positions][2] }
          target.segments[1] = segment_from_region(buf, pair, table.concat(selected, "\n"), false)
        end
      end
      for _, segment in ipairs(target.segments) do
        next_id = next_id + 1
        segment.id = "target-" .. next_id
        segment.raw = read_text(buf, segment.first, segment.last)
        if compare(segment.first, segment.last) == 0 then
          segment.guard_before, segment.guard_after = guard(buf, segment.first)
        end
        set_marks(target, segment)
      end
      target.revision = api.nvim_buf_get_changedtick(buf)
    end)
    local registry = observe(buf)
    if not registry then
      error("Could not track the source buffer")
    end
    registry[target] = true
  end)
  if not ok then
    M.dispose(target)
    return nil, tostring(err)
  end
  return target
end

function M.valid(target)
  if not target or target.disposed or target.invalid then
    return false
  end
  if not api.nvim_buf_is_valid(target.buf) or not api.nvim_buf_is_loaded(target.buf) then
    invalidate(target, "The source buffer was unloaded or deleted")
    return false
  end
  if not vim.bo[target.buf].modifiable then
    return false
  end
  for _, segment in ipairs(target.segments) do
    local a = api.nvim_buf_get_extmark_by_id(target.buf, ns, segment.start_mark, {})
    local b = api.nvim_buf_get_extmark_by_id(target.buf, ns, segment.end_mark, {})
    if #a == 0 or #b == 0 or compare(a, b) > 0 then
      invalidate(target, "The target's tracking marks were removed")
      return false
    end
    segment.first, segment.last = a, b
    local ok, raw = pcall(read_text, target.buf, a, b)
    if not ok or raw ~= segment.raw then
      invalidate(target)
      return false
    end
    if compare(a, b) == 0 then
      local before, after = guard(target.buf, a)
      if before ~= segment.guard_before or after ~= segment.guard_after then
        invalidate(target, "The text beside the insertion boundary changed")
        return false
      end
    end
  end
  return true
end

function M.envelope(target)
  if not M.valid(target) then
    return nil, target and target.invalid or "The target is not available or the buffer is not modifiable"
  end
  local result = {}
  for _, segment in ipairs(target.segments) do
    local before, after = surroundings(target.buf, segment.first, segment.last)
    result[#result + 1] = {
      id = segment.id, start = copy(segment.first), ["end"] = copy(segment.last),
      text = segment.text, before = before .. segment.prefix, after = segment.suffix .. after, block = segment.block,
      coordinates = "zero-based UTF-8 bytes; end-exclusive",
      virtual_start_offset = segment.virtual_start_offset or 0,
      virtual_end_offset = segment.virtual_end_offset or 0,
    }
  end
  return result
end

local function replacement_end(first, text)
  local parts = vim.split(text, "\n", { plain = true })
  if #parts == 1 then
    return { first[1], first[2] + #text }, parts
  end
  return { first[1] + #parts - 1, #parts[#parts] }, parts
end

function M.apply(target, replacements)
  if not M.valid(target) then
    return false, target and target.invalid or "The target is not available or the buffer is not modifiable"
  end
  if type(replacements) ~= "table" or #replacements ~= #target.segments then
    return false, "The edit must contain exactly one replacement for every target"
  end
  local by_id, count = {}, 0
  for key, replacement in pairs(replacements) do
    if type(key) ~= "number" or key < 1 or key > #target.segments or key % 1 ~= 0
      or type(replacement) ~= "table" or type(replacement.id) ~= "string"
      or type(replacement.text) ~= "string" or by_id[replacement.id] ~= nil then
      return false, "The edit contains an invalid or duplicate replacement"
    end
    by_id[replacement.id] = replacement.text
    count = count + 1
  end
  if count ~= #target.segments then
    return false, "The edit contains missing or extra replacements"
  end
  local planned = {}
  for i, segment in ipairs(target.segments) do
    local text = by_id[segment.id]
    if text == nil then
      return false, "The edit contains a missing or unknown target ID"
    end
    if segment.block and text:find("\n", 1, true) then
      return false, "Blockwise replacements cannot contain newlines"
    end
    local full = segment.prefix .. text .. segment.suffix
    local _, parts = replacement_end(segment.first, full)
    planned[i] = { text = text, full = full, parts = parts }
  end
  local undo_levels = vim.bo[target.buf].undolevels
  if undo_levels == -123456 then
    undo_levels = vim.go.undolevels
  end
  if undo_levels < 0 then
    return false, "Undo is disabled in the source buffer; enable it before applying the edit"
  end
  local changed = 0
  target.applying = true
  local ok, err = pcall(function()
    context_call(target, function()
      -- Documented undo-close-block. Do not inherit a pending user undo block.
      vim.cmd("let &g:undolevels = &g:undolevels")
      for i = #target.segments, 1, -1 do
        local segment, edit = target.segments[i], planned[i]
        if edit.full ~= segment.raw then
          if changed > 0 then
            vim.cmd("undojoin")
          end
          api.nvim_buf_set_text(target.buf, segment.first[1], segment.first[2], segment.last[1], segment.last[2], edit.parts)
          changed = changed + 1
        end
      end
      vim.cmd("let &g:undolevels = &g:undolevels")
    end)
  end)
  if not ok then
    if changed > 0 then
      pcall(context_call, target, function()
        vim.cmd("silent undo")
      end)
    end
    target.applying = false
    invalidate(target, "The source edit failed: " .. tostring(err))
    return false, target.invalid
  end
  for i, segment in ipairs(target.segments) do
    local edit = planned[i]
    local first = { segment.first[1], segment.first[2] + #segment.prefix }
    segment.first = first
    segment.last = replacement_end(first, edit.text)
    segment.raw, segment.text = edit.text, edit.text
    segment.prefix, segment.suffix = "", ""
    segment.virtual_start_offset, segment.virtual_end_offset = 0, 0
    if compare(segment.first, segment.last) == 0 then
      segment.guard_before, segment.guard_after = guard(target.buf, segment.first)
    end
    set_marks(target, segment)
  end
  target.applying = false
  target.revision = api.nvim_buf_get_changedtick(target.buf)
  M.highlight(target, target.highlighted)
  return true
end

function M.highlight(target, enabled)
  if not target or target.disposed or not api.nvim_buf_is_valid(target.buf) then
    return
  end
  target.highlighted = not not enabled
  for _, segment in ipairs(target.segments) do
    if segment.highlight_mark then
      pcall(api.nvim_buf_del_extmark, target.buf, ns, segment.highlight_mark)
      segment.highlight_mark = nil
    end
    if enabled and not target.invalid then
      local a = api.nvim_buf_get_extmark_by_id(target.buf, ns, segment.start_mark, {})
      local b = api.nvim_buf_get_extmark_by_id(target.buf, ns, segment.end_mark, {})
      if #a > 0 and #b > 0 then
        local opts = {
          end_row = b[1], end_col = b[2], hl_group = "Visual", priority = 150,
          right_gravity = true, end_right_gravity = false,
        }
        if compare(a, b) == 0 then
          opts.virt_text = { { "▏", "Visual" } }
          opts.virt_text_pos = "overlay"
        end
        segment.highlight_mark = api.nvim_buf_set_extmark(target.buf, ns, a[1], a[2], opts)
      end
    end
  end
end

function M.dispose(target)
  if not target or target.disposed then
    return
  end
  target.disposed = true
  if buffers[target.buf] then
    buffers[target.buf][target] = nil
  end
  if api.nvim_buf_is_valid(target.buf) then
    for _, segment in ipairs(target.segments) do
      for _, key in ipairs({ "start_mark", "end_mark", "highlight_mark" }) do
        if segment[key] then
          pcall(api.nvim_buf_del_extmark, target.buf, ns, segment[key])
        end
      end
    end
  end
end

return M
