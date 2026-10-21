local M = {}
local api = vim.api

local prompt = nil
local answer = nil
local namespace = api.nvim_create_namespace("nvim-claude-ui")

local function valid_win(win)
  return win and api.nvim_win_is_valid(win)
end

local function close_window(state, restore)
  if not state then return end
  if valid_win(state.win) then api.nvim_win_close(state.win, true) end
  if state.buf and api.nvim_buf_is_valid(state.buf) then api.nvim_buf_delete(state.buf, { force = true }) end
  if restore and valid_win(state.origin_win) then api.nvim_set_current_win(state.origin_win) end
end

local function dimensions(opts, line_count, desired_width)
  local editor_width = vim.o.columns
  local editor_height = vim.o.lines - vim.o.cmdheight
  local width = math.max(32, math.min(desired_width or 62, opts.float.max_width, editor_width - 4))
  local height = math.max(2, math.min(line_count, opts.float.max_height, editor_height - 4))
  return width, height
end

local function cursor_float_config(opts, height, width, title)
  local row = 1
  local col = 0
  local cursor_screen_row = vim.fn.screenrow()
  if cursor_screen_row + height + 3 > vim.o.lines then row = -height - 2 end
  return {
    relative = "cursor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = opts.float.border,
    title = " " .. title .. " ",
    title_pos = "left",
    noautocmd = true,
  }
end

function M.close_prompt()
  local current = prompt
  prompt = nil
  close_window(current, true)
end

function M.open_prompt(opts, title, on_submit, origin_win)
  M.close_prompt()
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(buf, "nvim-claude://prompt")
  api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  api.nvim_set_option_value("swapfile", false, { buf = buf })
  api.nvim_set_option_value("filetype", "markdown", { buf = buf })
  api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
  local width, height = dimensions(opts, 2, 62)
  local win = api.nvim_open_win(buf, true, cursor_float_config(opts, height, width, title))
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].winhighlight = "NormalFloat:NormalFloat,FloatBorder:FloatBorder,FloatTitle:Title"
  prompt = { buf = buf, win = win, origin_win = origin_win, submitted = false }

  local function resize()
    if not prompt or prompt.buf ~= buf or not valid_win(win) then return end
    local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
    local _, next_height = dimensions(opts, #lines, width)
    api.nvim_win_set_config(win, vim.tbl_extend("force", api.nvim_win_get_config(win), { height = next_height }))
  end

  local function submit()
    if not prompt or prompt.submitted then return end
    local text = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    if vim.trim(text) == "" then
      vim.notify("NvClaude: enter an instruction", vim.log.levels.WARN)
      return
    end
    prompt.submitted = true
    M.close_prompt()
    on_submit(text)
  end

  vim.keymap.set({ "i", "n" }, "<C-s>", submit, { buffer = buf, silent = true, desc = "Submit to Claude" })
  vim.keymap.set("n", "<CR>", submit, { buffer = buf, silent = true, desc = "Submit to Claude" })
  vim.keymap.set("n", "<Esc>", M.close_prompt, { buffer = buf, silent = true, desc = "Close Claude prompt" })
  api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, { buffer = buf, callback = resize })
  vim.cmd.startinsert()
end

function M.set_prompt_status(text)
  if prompt and valid_win(prompt.win) then
    local cfg = api.nvim_win_get_config(prompt.win)
    cfg.title = " " .. text .. " "
    api.nvim_win_set_config(prompt.win, cfg)
  end
end

function M.close_answer()
  local current = answer
  answer = nil
  close_window(current, true)
end

local function answer_resize(opts)
  if not answer or not valid_win(answer.win) then return end
  local lines = api.nvim_buf_get_lines(answer.buf, 0, -1, false)
  local width, height = dimensions(opts, #lines, 78)
  local editor_height = vim.o.lines - vim.o.cmdheight
  local row = math.max(1, math.floor((editor_height - height) / 3))
  local col = math.max(1, math.floor((vim.o.columns - width) / 2))
  api.nvim_win_set_config(answer.win, {
    relative = "editor", row = row, col = col, width = width, height = height,
    style = "minimal", border = opts.float.border, title = " " .. answer.title .. " ", title_pos = "left",
  })
end

function M.open_answer(opts, title, origin_win)
  if answer and valid_win(answer.win) then
    answer.title = title
    answer_resize(opts)
    return answer
  end
  M.close_answer()
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(buf, "nvim-claude://answer")
  api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  api.nvim_set_option_value("swapfile", false, { buf = buf })
  api.nvim_set_option_value("filetype", "markdown", { buf = buf })
  api.nvim_set_option_value("modifiable", true, { buf = buf })
  api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
  local width, height = dimensions(opts, 3, 78)
  local editor_height = vim.o.lines - vim.o.cmdheight
  local win = api.nvim_open_win(buf, false, {
    relative = "editor",
    row = math.max(1, math.floor((editor_height - height) / 3)),
    col = math.max(1, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = opts.float.border,
    title = " " .. title .. " ",
    title_pos = "left",
    noautocmd = true,
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  answer = { buf = buf, win = win, origin_win = origin_win, title = title, text = "" }
  local close = function() M.close_answer() end
  vim.keymap.set("n", "q", close, { buffer = buf, silent = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, silent = true })
  return answer
end

function M.answer_append(opts, text)
  if not answer or not api.nvim_buf_is_valid(answer.buf) then return end
  answer.text = answer.text .. text
  local lines = vim.split(answer.text, "\n", { plain = true })
  api.nvim_set_option_value("modifiable", true, { buf = answer.buf })
  api.nvim_buf_set_lines(answer.buf, 0, -1, false, lines)
  api.nvim_set_option_value("modifiable", false, { buf = answer.buf })
  answer_resize(opts)
end

function M.answer_set(opts, title, text, origin_win)
  M.open_answer(opts, title, origin_win)
  answer.text = ""
  M.answer_append(opts, text)
end

function M.info(opts, title, lines, origin_win)
  M.answer_set(opts, title, table.concat(lines, "\n"), origin_win)
  if answer and valid_win(answer.win) then api.nvim_set_current_win(answer.win) end
end

function M.input(prompt_text, default, callback)
  vim.ui.input({ prompt = prompt_text, default = default }, callback)
end

function M.select(items, options, callback)
  vim.ui.select(items, options, callback)
end

function M.edit_system_prompt(opts, text, on_save)
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(buf, "nvim-claude://system-prompt")
  api.nvim_set_option_value("buftype", "acwrite", { buf = buf })
  api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  api.nvim_set_option_value("swapfile", false, { buf = buf })
  api.nvim_set_option_value("filetype", "text", { buf = buf })
  api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n", { plain = true }))
  vim.cmd("tabnew")
  api.nvim_win_set_buf(0, buf)
  api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      local updated = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      on_save(updated, function(ok)
        if ok then api.nvim_set_option_value("modified", false, { buf = buf }) end
      end)
    end,
  })
end

function M.highlight_target(buf, marks)
  api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
  for _, mark in ipairs(marks or {}) do
    api.nvim_buf_set_extmark(buf, namespace, mark[1], mark[2], {
      end_row = mark[3], end_col = mark[4], hl_group = "Visual", priority = 120,
    })
  end
end

function M.clear_highlight(buf)
  if buf and api.nvim_buf_is_valid(buf) then api.nvim_buf_clear_namespace(buf, namespace, 0, -1) end
end

return M
