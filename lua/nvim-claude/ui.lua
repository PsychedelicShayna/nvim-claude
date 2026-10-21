local M = {}
local api = vim.api

local function lines(text)
  return vim.split(text or "", "\n", { plain = true })
end

local function focus(win)
  if win and api.nvim_win_is_valid(win) then
    api.nvim_set_current_win(win)
  end
end

local function screen()
  return math.max(1, vim.o.columns - 4), math.max(1, vim.o.lines - vim.o.cmdheight - 4)
end

local function scratch(filetype)
  local buf = api.nvim_create_buf(false, true)
  vim.b[buf].nvim_claude_ui = true
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = filetype or "markdown"
  return buf
end

local function window(buf, opts)
  local win = api.nvim_open_win(buf, opts.enter or false, opts.config)
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].winfixbuf = true
  return win
end

function M.prompt(opts)
  local max_width, max_height = screen()
  local width = math.min(64, max_width)
  local buf = scratch("text")
  local position = api.nvim_win_get_cursor(opts.origin)
  local cursor = vim.fn.screenpos(opts.origin, position[1], position[2] + 1)
  local row = math.max(0, math.min((cursor.row or 1), max_height - 3))
  local col = math.max(0, math.min((cursor.col or 1) - 1, max_width - width))
  local prompt = { buf = buf, origin = opts.origin }
  local config = {
    relative = "editor", row = row, col = col, width = width,
    height = math.min(3, max_height), style = "minimal", border = "rounded",
    title = " " .. opts.title .. " ", title_pos = "left",
    footer = " Ctrl-S submit · Esc normal, Esc close ", footer_pos = "left",
  }
  prompt.win = window(buf, { enter = true, config = config })

  function prompt:title(title)
    if self.win and api.nvim_win_is_valid(self.win) then
      api.nvim_win_set_config(self.win, { title = " " .. title .. " " })
    end
  end

  function prompt:close()
    if self.closed then return end
    self.closed = true
    if self.win and api.nvim_win_is_valid(self.win) then
      api.nvim_win_close(self.win, true)
    end
    if api.nvim_buf_is_valid(self.buf) then
      api.nvim_buf_delete(self.buf, { force = true })
    end
    focus(self.origin)
    if opts.on_close then opts.on_close() end
  end

  local function submit()
    local text = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    if opts.on_submit(text) then
      vim.cmd.stopinsert()
      prompt:close()
    end
  end
  vim.keymap.set({ "i", "n" }, "<C-s>", submit, { buffer = buf, silent = true })
  vim.keymap.set("n", "<CR>", submit, { buffer = buf, silent = true })
  vim.keymap.set("n", "<Esc>", function() prompt:close() end, { buffer = buf, silent = true })
  api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "VimResized" }, {
    buffer = buf,
    callback = function()
      if not prompt.win or not api.nvim_win_is_valid(prompt.win) then return end
      local sw, sh = screen()
      local w = math.min(64, sw)
      local count = 0
      for _, line in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
        count = count + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / w))
      end
      local h = math.min(math.max(3, count), math.max(1, math.floor(sh / 3)))
      api.nvim_win_set_config(prompt.win, {
        width = w, height = h, row = math.min(row, math.max(0, sh - h)),
        col = math.min(col, math.max(0, sw - w)),
      })
    end,
  })
  api.nvim_create_autocmd("BufWipeout", {
    buffer = buf, once = true,
    callback = function()
      if not prompt.closed then
        prompt.closed = true
        if opts.on_close then opts.on_close() end
      end
    end,
  })
  api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(prompt.win), once = true,
    callback = function()
      if not prompt.closed then prompt:close() end
    end,
  })
  vim.cmd.startinsert()
  return prompt
end

function M.answer(opts)
  local buf = scratch("markdown")
  local answer = { buf = buf, origin = opts.origin, text = "", title = opts.title or "Claude" }
  local max_width, max_height = screen()
  local width = math.min(88, max_width)
  local height = math.min(math.max(4, math.floor(max_height * 0.55)), max_height)
  local config = {
    relative = "editor", row = math.floor((max_height - height) / 2),
    col = math.floor((max_width - width) / 2), width = width, height = height,
    style = "minimal", border = "rounded", title = " " .. answer.title .. " ",
    footer = " q / Esc close · :NvClaude cancel interrupts ",
  }
  answer.win = window(buf, { enter = opts.enter == true, config = config })

  function answer:set(text, title)
    self.text = text or ""
    if not api.nvim_buf_is_valid(self.buf) then return end
    api.nvim_buf_set_lines(self.buf, 0, -1, false, lines(self.text))
    vim.bo[self.buf].modified = false
    if title then self.title = title end
    if self.win and api.nvim_win_is_valid(self.win) then
      api.nvim_win_set_config(self.win, { title = " " .. self.title .. " " })
    end
  end

  function answer:close()
    if self.win and api.nvim_win_is_valid(self.win) then api.nvim_win_close(self.win, true) end
    self.win = nil
    focus(self.origin)
  end

  function answer:discard()
    self:close()
    if api.nvim_buf_is_valid(self.buf) then api.nvim_buf_delete(self.buf, { force = true }) end
  end

  vim.keymap.set("n", "q", function() answer:close() end, { buffer = buf, silent = true })
  vim.keymap.set("n", "<Esc>", function() answer:close() end, { buffer = buf, silent = true })
  answer:set(opts.text or "")
  return answer
end

function M.system(text, save)
  local origin = api.nvim_get_current_win()
  local buf = scratch("text")
  vim.bo[buf].buftype = "acwrite"
  api.nvim_buf_set_name(buf, "nvim-claude-system://" .. buf)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines(text))
  vim.bo[buf].modified = false
  vim.cmd("botright split")
  local win = api.nvim_get_current_win()
  api.nvim_win_set_buf(win, buf)
  api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      local changedtick = api.nvim_buf_get_changedtick(buf)
      save(table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n"), function(ok)
        if ok and api.nvim_buf_is_valid(buf) and api.nvim_buf_get_changedtick(buf) == changedtick then
          vim.bo[buf].modified = false
        end
      end)
    end,
  })
  vim.keymap.set("n", "q", function()
    if vim.bo[buf].modified then
      vim.notify("System prompt has unsaved changes; use :write or :close!", vim.log.levels.WARN)
      return
    end
    api.nvim_win_close(win, true)
    focus(origin)
  end, { buffer = buf, silent = true })
  return buf
end

return M
