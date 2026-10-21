local M = {}

local answer_windows = {}

local function valid_window(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function restore_window(win)
  if valid_window(win) then
    pcall(vim.api.nvim_set_current_win, win)
  end
end

local function dimensions(width, height)
  return math.max(20, math.min(width, vim.o.columns - 4)), math.max(1, math.min(height, vim.o.lines - 6))
end

local function set_float_options(buf)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].undofile = false
end

function M.prompt(options)
  local origin = options.origin_win
  local width, height = dimensions(options.width or 60, 1)
  local buf = vim.api.nvim_create_buf(false, true)
  set_float_options(buf)
  vim.bo[buf].filetype = "nvim-claude-prompt"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " " .. options.title .. " ",
    title_pos = "left",
  })
  vim.wo[win].wrap = true
  vim.wo[win].winhighlight = "NormalFloat:NormalFloat,FloatBorder:FloatBorder"

  local closed = false
  local function finish(submit)
    if closed then
      return
    end
    closed = true
    local lines = vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_lines(buf, 0, -1, false) or {}
    local text = table.concat(lines, "\n")
    if valid_window(win) then
      vim.api.nvim_win_close(win, true)
    end
    restore_window(origin)
    if submit then
      options.on_submit(text)
    elseif options.on_cancel then
      options.on_cancel()
    end
  end

  local function grow()
    if not valid_window(win) or not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local display_lines = 0
    for _, line in ipairs(lines) do
      display_lines = display_lines + math.max(1, math.ceil(math.max(1, vim.fn.strdisplaywidth(line)) / width))
    end
    vim.api.nvim_win_set_height(win, select(2, dimensions(width, math.min(display_lines, 10))))
  end

  local group = vim.api.nvim_create_augroup("NvClaudePrompt" .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, { group = group, buffer = buf, callback = grow })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = buf,
    once = true,
    callback = function()
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })

  local map_opts = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set({ "n", "i" }, "<C-s>", function()
    vim.cmd("stopinsert")
    finish(true)
  end, map_opts)
  vim.keymap.set("n", "<CR>", function() finish(true) end, map_opts)
  vim.keymap.set("n", "<Esc>", function() finish(false) end, map_opts)
  vim.cmd("startinsert")
  return { buffer = buf, window = win, close = function() finish(false) end }
end

function M.answer(options)
  local width, height = dimensions(options.width or 76, options.height or 12)
  local buf = vim.api.nvim_create_buf(false, true)
  set_float_options(buf)
  vim.bo[buf].filetype = options.filetype or "markdown"
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " " .. (options.title or "Claude") .. " ",
    title_pos = "left",
  })
  vim.wo[win].wrap = true
  local state = { buffer = buf, window = win, origin_win = options.origin_win, text = "" }
  answer_windows[buf] = state

  local function close()
    if valid_window(win) then
      vim.api.nvim_win_close(win, true)
    end
    answer_windows[buf] = nil
    restore_window(state.origin_win)
  end
  vim.keymap.set("n", "q", close, { buffer = buf, silent = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, silent = true })
  return state
end

function M.append(state, chunk)
  if not state or not vim.api.nvim_buf_is_valid(state.buffer) then
    return
  end
  state.text = state.text .. chunk
  local lines = vim.split(state.text, "\n", { plain = true })
  vim.bo[state.buffer].modifiable = true
  vim.api.nvim_buf_set_lines(state.buffer, 0, -1, false, lines)
  vim.bo[state.buffer].modifiable = false
  if valid_window(state.window) then
    local last = #lines
    pcall(vim.api.nvim_win_set_cursor, state.window, { last, #lines[last] })
  end
end

function M.replace(state, text)
  if not state or not vim.api.nvim_buf_is_valid(state.buffer) then
    return
  end
  state.text = ""
  M.append(state, text)
end

function M.show_text(title, text, origin_win, filetype)
  local state = M.answer({ title = title, origin_win = origin_win, filetype = filetype })
  M.replace(state, text)
  return state
end

function M.set_title(state, title)
  if state and valid_window(state.window) then
    vim.api.nvim_win_set_config(state.window, { title = " " .. title .. " ", title_pos = "left" })
  end
end

return M
