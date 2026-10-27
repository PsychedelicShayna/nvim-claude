-- Prompt float (one reused scratch buffer) and answer/result floats.
local api = vim.api

local M = {}

local prompt_buf = nil
local prompt_win = nil
local prompt_ctx = nil -- { title, on_submit, anchor_win, anchor_pos }
local answer_buf = nil
local answer_win = nil
local answer_origin = nil

local MIN_HEIGHT = 2

local function scratch(name, filetype)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].buflisted = false
  vim.bo[buf].filetype = filetype
  pcall(api.nvim_buf_set_name, buf, name)
  return buf
end

local function close_prompt()
  if prompt_win and api.nvim_win_is_valid(prompt_win) then
    api.nvim_win_close(prompt_win, true)
  end
  prompt_win = nil
end

local function restore(win)
  if win and api.nvim_win_is_valid(win) then
    api.nvim_set_current_win(win)
  end
end

local function prompt_text()
  local lines = api.nvim_buf_get_lines(prompt_buf, 0, -1, false)
  return vim.trim(table.concat(lines, "\n"))
end

local function submit()
  local ctx = prompt_ctx
  if not ctx then
    return
  end
  local text = prompt_text()
  vim.cmd.stopinsert()
  close_prompt()
  restore(ctx.anchor_win)
  if text == "" then
    if ctx.on_cancel then
      ctx.on_cancel()
    end
    return
  end
  prompt_ctx = nil
  ctx.on_submit(text)
end

local function dismiss()
  local ctx = prompt_ctx
  vim.cmd.stopinsert()
  close_prompt()
  if ctx then
    restore(ctx.anchor_win)
    if ctx.on_cancel then
      ctx.on_cancel()
    end
  end
  prompt_ctx = nil
end

local function resize()
  if not (prompt_win and api.nvim_win_is_valid(prompt_win)) then
    return
  end
  local cfg = api.nvim_win_get_config(prompt_win)
  local width = cfg.width
  local rows = 0
  for _, line in ipairs(api.nvim_buf_get_lines(prompt_buf, 0, -1, false)) do
    rows = rows + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / width))
  end
  local max_h = math.max(MIN_HEIGHT, math.floor(vim.o.lines * 0.4))
  local height = math.min(max_h, math.max(MIN_HEIGHT, rows + 1))
  if height ~= cfg.height then
    api.nvim_win_set_config(prompt_win, { height = height })
  end
end

local function ensure_prompt_buf()
  if prompt_buf and api.nvim_buf_is_valid(prompt_buf) then
    return prompt_buf
  end
  prompt_buf = scratch("nvim-claude://prompt", "markdown")
  vim.bo[prompt_buf].undolevels = 1000
  local o = { buffer = prompt_buf, silent = true, nowait = true }
  vim.keymap.set({ "i", "n" }, "<C-s>", submit, o)
  vim.keymap.set("n", "<CR>", submit, o)
  vim.keymap.set("n", "<Esc>", dismiss, o)
  vim.keymap.set("n", "q", dismiss, o)
  api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, { buffer = prompt_buf, callback = resize })
  api.nvim_create_autocmd("WinLeave", {
    buffer = prompt_buf,
    callback = function()
      vim.schedule(function()
        if prompt_win and api.nvim_win_is_valid(prompt_win) and api.nvim_get_current_win() ~= prompt_win then
          dismiss()
        end
      end)
    end,
  })
  return prompt_buf
end

-- Open the prompt float near the cursor of the current window.
-- opts: { title, on_submit(text), on_cancel() }
function M.prompt(opts)
  dismiss()
  local buf = ensure_prompt_buf()
  -- Clear old text as an ordinary undoable change so `u` brings it back.
  if prompt_text() ~= "" then
    api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
  end
  local anchor_win = api.nvim_get_current_win()
  local width = math.max(40, math.min(90, math.floor(vim.o.columns * 0.5)))
  local screen_row = vim.fn.screenrow()
  local below = screen_row + MIN_HEIGHT + 3 <= vim.o.lines - vim.o.cmdheight
  prompt_ctx = { anchor_win = anchor_win, on_submit = opts.on_submit, on_cancel = opts.on_cancel }
  prompt_win = api.nvim_open_win(buf, true, {
    relative = "cursor",
    row = below and 1 or -(MIN_HEIGHT + 2),
    col = 0,
    width = width,
    height = MIN_HEIGHT,
    border = "rounded",
    style = "minimal",
    title = " " .. opts.title .. " ",
    title_pos = "left",
    footer = " <C-s> send · <Esc> close ",
    footer_pos = "right",
    zindex = 60,
  })
  vim.wo[prompt_win].wrap = true
  vim.wo[prompt_win].linebreak = true
  vim.cmd.startinsert()
end

local function ensure_answer_buf()
  if answer_buf and api.nvim_buf_is_valid(answer_buf) then
    return answer_buf
  end
  answer_buf = scratch("nvim-claude://answer", "markdown")
  local function close()
    if answer_win and api.nvim_win_is_valid(answer_win) then
      api.nvim_win_close(answer_win, true)
    end
    answer_win = nil
    restore(answer_origin)
  end
  vim.keymap.set("n", "q", close, { buffer = answer_buf, silent = true, nowait = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = answer_buf, silent = true, nowait = true })
  return answer_buf
end

local function answer_size(lines)
  local width = math.max(50, math.min(100, math.floor(vim.o.columns * 0.6)))
  local rows = 0
  for _, l in ipairs(lines) do
    rows = rows + math.max(1, math.ceil(vim.fn.strdisplaywidth(l) / width))
  end
  local height = math.max(3, math.min(rows, math.floor(vim.o.lines * 0.6)))
  return width, height
end

-- Show (or replace) the answer float. focus=false leaves focus where it is.
function M.answer(title, text, focus)
  local buf = ensure_answer_buf()
  local lines = vim.split(text or "", "\n", { plain = true })
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local width, height = answer_size(lines)
  local cfg = {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    border = "rounded",
    style = "minimal",
    title = " " .. title .. " ",
    title_pos = "left",
    footer = " q close ",
    footer_pos = "right",
    zindex = 55,
  }
  if answer_win and api.nvim_win_is_valid(answer_win) then
    api.nvim_win_set_config(answer_win, cfg)
  else
    answer_origin = api.nvim_get_current_win()
    answer_win = api.nvim_open_win(buf, focus ~= false, cfg)
    vim.wo[answer_win].wrap = true
    vim.wo[answer_win].linebreak = true
    vim.wo[answer_win].conceallevel = 2
  end
  if focus ~= false and api.nvim_get_current_win() ~= answer_win then
    answer_origin = api.nvim_get_current_win()
    api.nvim_set_current_win(answer_win)
  end
  return answer_win
end

-- Append streamed text to the open answer float without stealing focus.
function M.answer_append(text)
  if not (answer_buf and api.nvim_buf_is_valid(answer_buf)) then
    return
  end
  vim.bo[answer_buf].modifiable = true
  local last = api.nvim_buf_line_count(answer_buf)
  local tail = api.nvim_buf_get_lines(answer_buf, last - 1, last, false)[1] or ""
  local parts = vim.split(text, "\n", { plain = true })
  parts[1] = tail .. parts[1]
  api.nvim_buf_set_lines(answer_buf, last - 1, last, false, parts)
  vim.bo[answer_buf].modifiable = false
  if answer_win and api.nvim_win_is_valid(answer_win) then
    local lines = api.nvim_buf_get_lines(answer_buf, 0, -1, false)
    local width, height = answer_size(lines)
    api.nvim_win_set_config(answer_win, { width = width, height = height })
    api.nvim_win_set_cursor(answer_win, { api.nvim_buf_line_count(answer_buf), 0 })
  end
end

function M.answer_title(title)
  if answer_win and api.nvim_win_is_valid(answer_win) then
    api.nvim_win_set_config(answer_win, { title = " " .. title .. " ", title_pos = "left" })
  end
end

function M.prompt_buf()
  return prompt_buf
end

return M
