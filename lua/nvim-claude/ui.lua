local M = {}
local prompt_state
local answers = {}

local function dimensions(max_width, max_height)
  local width = math.min(max_width, math.max(30, vim.o.columns - 4))
  local height = math.min(max_height, math.max(1, vim.o.lines - 4))
  return width, height
end

local function restore(win)
  if win and vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_set_current_win, win) end
end

function M.prompt(title, origin, submit)
  if prompt_state and vim.api.nvim_win_is_valid(prompt_state.win) then vim.api.nvim_set_current_win(prompt_state.win); return end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  local width = dimensions(64, 12)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "cursor", row = 1, col = 0, width = width, height = 1,
    style = "minimal", border = "rounded", title = " " .. title .. " ", title_pos = "center",
  })
  prompt_state = { buf = buf, win = win, origin = origin }
  local function close()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    prompt_state = nil
    restore(origin)
  end
  local function send()
    local instruction = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    if vim.trim(instruction) == "" then return end
    close()
    submit(instruction)
  end
  vim.keymap.set({ "i", "n" }, "<C-s>", send, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<CR>", send, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, nowait = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = buf,
    callback = function()
      if not vim.api.nvim_win_is_valid(win) then return end
      local count = vim.api.nvim_buf_line_count(buf)
      vim.api.nvim_win_set_height(win, math.min(math.max(count, 1), 12))
    end,
  })
  vim.cmd.startinsert()
end

local function answer_window(title, origin)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  local width, height = dimensions(78, math.floor(vim.o.lines * 0.55))
  local row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1)
  local col = math.max(0, math.floor((vim.o.columns - width) / 2))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor", row = row, col = col, width = width, height = height,
    style = "minimal", border = "rounded", title = " " .. title .. " ", title_pos = "center",
  })
  local function close()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    restore(origin)
  end
  vim.keymap.set("n", "q", close, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, nowait = true })
  return { buf = buf, win = win, origin = origin, text = "" }
end

function M.answer(id, title, origin)
  if not answers[id] or not vim.api.nvim_buf_is_valid(answers[id].buf) then answers[id] = answer_window(title, origin) end
  return answers[id]
end

function M.append(id, text, title, origin)
  local answer = M.answer(id, title, origin)
  answer.text = answer.text .. text
  vim.bo[answer.buf].modifiable = true
  vim.api.nvim_buf_set_lines(answer.buf, 0, -1, false, vim.split(answer.text, "\n", { plain = true }))
  if vim.api.nvim_win_is_valid(answer.win) then vim.api.nvim_win_set_cursor(answer.win, { vim.api.nvim_buf_line_count(answer.buf), 0 }) end
end

function M.finish(id, text, title, origin)
  local answer = M.answer(id, title, origin)
  answer.text = text
  vim.bo[answer.buf].modifiable = true
  vim.api.nvim_buf_set_lines(answer.buf, 0, -1, false, vim.split(text, "\n", { plain = true }))
  vim.bo[answer.buf].modifiable = false
end

function M.select(prompt, items, format, callback)
  vim.ui.select(items, { prompt = prompt, format_item = format }, callback)
end

function M.input(prompt, default, callback)
  vim.ui.input({ prompt = prompt, default = default }, callback)
end

return M
