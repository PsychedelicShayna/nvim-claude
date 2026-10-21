local M = {}

local api = vim.api
local ui_serial = 0

local function next_name(kind)
  ui_serial = ui_serial + 1
  return ("nvim-claude://%s/%d"):format(kind, ui_serial)
end

local function valid_window(winid)
  return type(winid) == "number" and api.nvim_win_is_valid(winid)
end

local function valid_buffer(bufnr)
  return type(bufnr) == "number" and api.nvim_buf_is_valid(bufnr)
end

local function restore_window(winid)
  if valid_window(winid) then
    pcall(api.nvim_set_current_win, winid)
  end
end

local function notify_error(message)
  vim.notify(message, vim.log.levels.ERROR, { title = "nvim-claude" })
end

local function scratch_buffer(kind, filetype, buftype)
  local bufnr = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(bufnr, next_name(kind))
  api.nvim_set_option_value("buftype", buftype or "nofile", { buf = bufnr })
  api.nvim_set_option_value("bufhidden", "hide", { buf = bufnr })
  api.nvim_set_option_value("swapfile", false, { buf = bufnr })
  api.nvim_set_option_value("undofile", false, { buf = bufnr })
  if filetype then
    api.nvim_set_option_value("filetype", filetype, { buf = bufnr })
  end
  return bufnr
end

local function set_lines(bufnr, lines, modifiable_after)
  if not valid_buffer(bufnr) then
    return
  end
  api.nvim_set_option_value("modifiable", true, { buf = bufnr })
  api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  api.nvim_set_option_value("modifiable", modifiable_after == true, { buf = bufnr })
end

local function text_lines(text)
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

local function buffer_text(bufnr)
  return table.concat(api.nvim_buf_get_lines(bufnr, 0, -1, true), "\n")
end

local function clamp(value, low, high)
  return math.max(low, math.min(value, high))
end

local function centered_config(width, height, title)
  local columns = math.max(1, vim.o.columns)
  local usable_lines = math.max(1, vim.o.lines - vim.o.cmdheight)
  width = clamp(width, 1, math.max(1, columns - 4))
  height = clamp(height, 1, math.max(1, usable_lines - 4))
  return {
    relative = "editor",
    row = math.max(0, math.floor((usable_lines - height - 2) / 2)),
    col = math.max(0, math.floor((columns - width - 2) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "center",
  }
end

local function cursor_config(origin_win, width, height, title)
  local columns = math.max(1, vim.o.columns)
  local usable_lines = math.max(1, vim.o.lines - vim.o.cmdheight)
  width = clamp(width, 1, math.max(1, columns - 4))
  height = clamp(height, 1, math.max(1, usable_lines - 4))

  local screen = { row = 1, col = 1 }
  if valid_window(origin_win) then
    local cursor = api.nvim_win_get_cursor(origin_win)
    local ok, position = pcall(vim.fn.screenpos, origin_win, cursor[1], cursor[2] + 1)
    if ok and position and position.row and position.row > 0 then
      screen = position
    end
  end

  local below = screen.row
  local row
  if below + height + 2 <= usable_lines then
    row = below
  else
    row = math.max(0, screen.row - height - 2)
  end
  local col = clamp((screen.col or 1) - 1, 0, math.max(0, columns - width - 2))
  return {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "center",
  }
end

local function open_window(bufnr, config, enter)
  local winid = api.nvim_open_win(bufnr, enter ~= false, config)
  api.nvim_set_option_value("wrap", true, { win = winid })
  api.nvim_set_option_value("linebreak", true, { win = winid })
  return winid
end

local function map(bufnr, mode, lhs, callback, description)
  vim.keymap.set(mode, lhs, callback, {
    buffer = bufnr,
    nowait = true,
    silent = true,
    desc = description,
  })
end

local function title_text(label, status)
  if status and status ~= "" then
    return (" %s · %s "):format(label, status)
  end
  return (" %s "):format(label)
end

function M.prompt(opts)
  opts = opts or {}
  local origin_win = opts.origin_win or api.nvim_get_current_win()
  local operation = opts.operation or "ask"
  local label = ("Claude %s · %s"):format(operation, opts.model or "model")
  local state = {
    origin_win = origin_win,
    target = opts.target,
    status = opts.status,
    closed = false,
    submitted = false,
  }
  local handle = {}
  local bufnr = scratch_buffer("prompt", "nvim-claude-prompt")
  state.bufnr = bufnr
  set_lines(bufnr, text_lines(opts.initial or ""), true)

  local width = opts.width or 52
  local max_height = opts.max_height or math.min(12, math.max(3, vim.o.lines - vim.o.cmdheight - 6))
  local config = cursor_config(origin_win, width, 1, title_text(label, state.status))
  local winid = open_window(bufnr, config, true)
  state.winid = winid

  if state.target then
    local ok, targets = pcall(require, "nvim-claude.target")
    if ok then
      targets.highlight(state.target, opts.highlight_group)
      state.target_api = targets
    end
  end

  local function resize()
    if not valid_window(state.winid) or not valid_buffer(bufnr) then
      return
    end
    local rows = 0
    for _, line in ipairs(api.nvim_buf_get_lines(bufnr, 0, -1, true)) do
      rows = rows + math.max(1, math.ceil(math.max(1, vim.fn.strdisplaywidth(line)) / width))
    end
    rows = clamp(rows, 1, max_height)
    local next_config = cursor_config(origin_win, width, rows, title_text(label, state.status))
    pcall(api.nvim_win_set_config, state.winid, next_config)
  end

  local function close(reason)
    if state.closed then
      return
    end
    state.closed = true
    if state.target_api and state.target then
      state.target_api.clear_highlight(state.target)
    end
    if valid_window(state.winid) then
      pcall(api.nvim_win_close, state.winid, true)
    end
    if valid_buffer(bufnr) then
      pcall(api.nvim_buf_delete, bufnr, { force = true })
    end
    restore_window(origin_win)
    if reason == "cancel" and opts.on_cancel then
      opts.on_cancel(handle)
    end
  end

  local function submit()
    if state.closed then
      return
    end
    local text = buffer_text(bufnr)
    local ok, accepted, message = pcall(opts.on_submit or function()
      return true
    end, text, handle)
    if not ok then
      notify_error(accepted)
      return
    end
    if accepted == false then
      if message then
        handle:set_status(message)
      end
      return
    end
    state.submitted = true
    close("submit")
  end

  function handle:set_status(status)
    state.status = status
    if valid_window(state.winid) then
      resize()
    end
  end

  function handle:text()
    if valid_buffer(bufnr) then
      return buffer_text(bufnr)
    end
    return nil
  end

  function handle:submit()
    submit()
  end

  function handle:close()
    close("cancel")
  end

  function handle:is_open()
    return not state.closed and valid_window(state.winid)
  end

  handle.bufnr = bufnr
  handle.winid = winid

  map(bufnr, { "n", "i" }, "<C-s>", submit, "Submit Claude prompt")
  map(bufnr, "n", "<CR>", submit, "Submit Claude prompt")
  map(bufnr, "n", "<Esc>", function()
    close("cancel")
  end, "Dismiss Claude prompt")

  api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = bufnr,
    callback = resize,
  })
  resize()
  vim.schedule(function()
    if valid_window(state.winid) and api.nvim_get_current_win() == state.winid then
      vim.cmd("startinsert")
    end
  end)
  return handle
end

local function text_float(opts)
  opts = opts or {}
  local origin_win = opts.origin_win or api.nvim_get_current_win()
  local state = {
    origin_win = origin_win,
    text = opts.text or "",
    status = opts.status,
    disposed = false,
  }
  local handle = {}
  local bufnr = scratch_buffer(opts.kind or "answer", opts.filetype or "markdown")
  state.bufnr = bufnr

  local width = opts.width or math.min(88, math.max(30, vim.o.columns - 12))
  local height = opts.height or math.min(24, math.max(6, vim.o.lines - vim.o.cmdheight - 8))
  local label = opts.title or "Claude answer"

  local function render()
    if not valid_buffer(bufnr) then
      return
    end
    set_lines(bufnr, text_lines(state.text), false)
  end

  local function open()
    if state.disposed or not valid_buffer(bufnr) then
      return nil
    end
    if valid_window(state.winid) then
      api.nvim_set_current_win(state.winid)
      return state.winid
    end
    state.winid = open_window(
      bufnr,
      centered_config(width, height, title_text(label, state.status)),
      true
    )
    handle.winid = state.winid
    api.nvim_set_option_value("cursorline", false, { win = state.winid })
    return state.winid
  end

  local function close()
    if valid_window(state.winid) then
      pcall(api.nvim_win_close, state.winid, true)
    end
    state.winid = nil
    restore_window(origin_win)
    if opts.on_close then
      opts.on_close(handle)
    end
    if opts.dispose_on_close then
      handle:dispose()
    end
  end

  function handle:append(delta)
    if state.disposed then
      return false
    end
    state.text = state.text .. (delta or "")
    render()
    if valid_window(state.winid) and opts.follow ~= false then
      local line_count = api.nvim_buf_line_count(bufnr)
      pcall(api.nvim_win_set_cursor, state.winid, { line_count, 0 })
    end
    return true
  end

  function handle:set_text(text)
    if state.disposed then
      return false
    end
    state.text = text or ""
    render()
    return true
  end

  function handle:text()
    return state.text
  end

  function handle:set_status(status)
    state.status = status
    if valid_window(state.winid) then
      pcall(api.nvim_win_set_config, state.winid, centered_config(width, height, title_text(label, status)))
    end
  end

  function handle:open()
    return open()
  end

  function handle:close()
    close()
  end

  function handle:is_open()
    return valid_window(state.winid)
  end

  function handle:dispose()
    if state.disposed then
      return
    end
    state.disposed = true
    if valid_window(state.winid) then
      pcall(api.nvim_win_close, state.winid, true)
    end
    state.winid = nil
    if valid_buffer(bufnr) then
      pcall(api.nvim_buf_delete, bufnr, { force = true })
    end
  end

  handle.bufnr = bufnr
  render()
  map(bufnr, "n", "q", close, "Close Claude result")
  map(bufnr, "n", "<Esc>", close, "Close Claude result")
  open()
  return handle
end

function M.answer(opts)
  opts = vim.tbl_extend("force", { kind = "answer", title = "Claude answer" }, opts or {})
  return text_float(opts)
end
function M.result(opts)
  opts = vim.tbl_extend("force", { kind = "result", title = "Claude result" }, opts or {})
  return text_float(opts)
end


function M.info(opts)
  opts = opts or {}
  local content = opts.text or opts.lines or ""
  if type(content) == "table" then
    content = table.concat(content, "\n")
  end
  return text_float(vim.tbl_extend("force", opts, {
    kind = "info",
    title = opts.title or "nvim-claude info",
    text = content,
    filetype = opts.filetype or "text",
    dispose_on_close = true,
  }))
end

function M.picker(opts)
  opts = opts or {}
  local items = opts.items or {}
  local origin_win = opts.origin_win or api.nvim_get_current_win()
  local state = { closed = false }
  local handle = {}
  local bufnr = scratch_buffer("picker", "nvim-claude-picker")
  state.bufnr = bufnr

  local labels = {}
  local max_width = vim.fn.strdisplaywidth(opts.title or "Select")
  for index, item in ipairs(items) do
    local label
    if opts.format_item then
      label = opts.format_item(item, index)
    elseif type(item) == "table" then
      label = item.label or item.name or item.id or vim.inspect(item)
    else
      label = tostring(item)
    end
    labels[index] = label
    max_width = math.max(max_width, vim.fn.strdisplaywidth(label))
  end
  if #labels == 0 then
    labels[1] = "(no items)"
  end
  set_lines(bufnr, labels, false)

  local width = clamp(opts.width or max_width + 2, 20, math.max(20, vim.o.columns - 4))
  local height = clamp(#labels, 1, math.max(1, math.min(opts.max_height or 18, vim.o.lines - vim.o.cmdheight - 4)))
  local winid = open_window(bufnr, centered_config(width, height, opts.title or "Select"), true)
  state.winid = winid
  api.nvim_set_option_value("cursorline", true, { win = winid })
  api.nvim_set_option_value("wrap", false, { win = winid })
  if #items > 0 then
    local initial = clamp(opts.initial or 1, 1, #items)
    api.nvim_win_set_cursor(winid, { initial, 0 })
  end

  local function close(cancelled)
    if state.closed then
      return
    end
    state.closed = true
    if valid_window(state.winid) then
      pcall(api.nvim_win_close, state.winid, true)
    end
    if valid_buffer(bufnr) then
      pcall(api.nvim_buf_delete, bufnr, { force = true })
    end
    restore_window(origin_win)
    if cancelled and opts.on_cancel then
      opts.on_cancel(handle)
    end
  end

  local function choose()
    if state.closed or #items == 0 then
      return
    end
    local index = api.nvim_win_get_cursor(state.winid)[1]
    local item = items[index]
    close(false)
    if opts.on_select then
      opts.on_select(item, index, handle)
    end
  end

  function handle:close()
    close(true)
  end

  function handle:choose()
    choose()
  end

  function handle:is_open()
    return not state.closed and valid_window(state.winid)
  end

  handle.bufnr = bufnr
  handle.winid = winid
  map(bufnr, "n", "<CR>", choose, "Choose Claude option")
  map(bufnr, "n", "q", function()
    close(true)
  end, "Cancel Claude picker")
  map(bufnr, "n", "<Esc>", function()
    close(true)
  end, "Cancel Claude picker")
  return handle
end

function M.system_prompt(opts)
  opts = opts or {}
  local origin_win = opts.origin_win or api.nvim_get_current_win()
  local state = { closed = false, disposed = false }
  local handle = {}
  local bufnr = scratch_buffer("system-prompt", opts.filetype or "text", "acwrite")
  state.bufnr = bufnr
  set_lines(bufnr, text_lines(opts.text or ""), true)
  api.nvim_set_option_value("endofline", (opts.text or ""):sub(-1) == "\n", { buf = bufnr })
  api.nvim_set_option_value("modified", false, { buf = bufnr })

  local width = opts.width or math.min(92, math.max(40, vim.o.columns - 10))
  local height = opts.height or math.min(28, math.max(8, vim.o.lines - vim.o.cmdheight - 6))
  local title = opts.title or "Claude system prompt"
  local winid = open_window(bufnr, centered_config(width, height, title), true)
  state.winid = winid

  local function current_text()
    return buffer_text(bufnr)
  end

  local function save()
    if state.disposed or not valid_buffer(bufnr) then
      return false
    end
    local ok, accepted, message = pcall(opts.on_save or function()
      return true
    end, current_text(), handle)
    if not ok then
      notify_error(accepted)
      return false
    end
    if accepted == false then
      if message then
        notify_error(message)
      end
      return false
    end
    api.nvim_set_option_value("modified", false, { buf = bufnr })
    if opts.on_saved then
      opts.on_saved(handle)
    end
    return true
  end

  local function close()
    if state.closed then
      return
    end
    state.closed = true
    if valid_window(state.winid) then
      pcall(api.nvim_win_close, state.winid, true)
    end
    state.winid = nil
    restore_window(origin_win)
    if opts.on_close then
      opts.on_close(handle)
    end
  end

  function handle:save()
    return save()
  end

  function handle:text()
    if valid_buffer(bufnr) then
      return current_text()
    end
    return nil
  end

  function handle:open()
    if state.disposed or not valid_buffer(bufnr) then
      return nil
    end
    state.closed = false
    if not valid_window(state.winid) then
      state.winid = open_window(bufnr, centered_config(width, height, title), true)
      handle.winid = state.winid
    else
      api.nvim_set_current_win(state.winid)
    end
    return state.winid
  end

  function handle:close()
    close()
  end

  function handle:dispose()
    if state.disposed then
      return
    end
    close()
    state.disposed = true
    if valid_buffer(bufnr) then
      pcall(api.nvim_buf_delete, bufnr, { force = true })
    end
  end

  function handle:is_open()
    return valid_window(state.winid)
  end

  handle.bufnr = bufnr
  handle.winid = winid
  map(bufnr, { "n", "i" }, "<C-s>", save, "Save Claude system prompt")
  map(bufnr, "n", "q", close, "Close Claude system prompt")
  map(bufnr, "n", "<Esc>", close, "Close Claude system prompt")
  api.nvim_create_autocmd("BufWriteCmd", {
    buffer = bufnr,
    callback = save,
  })
  if opts.start_insert then
    vim.schedule(function()
      if valid_window(state.winid) and api.nvim_get_current_win() == state.winid then
        vim.cmd("startinsert")
      end
    end)
  end
  return handle
end

return M
