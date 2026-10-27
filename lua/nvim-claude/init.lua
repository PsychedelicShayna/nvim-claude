-- nvim-claude: cursor-local editing with Claude through the Python Agent SDK.
local api = vim.api
local config = require("nvim-claude.config")
local bridge = require("nvim-claude.bridge")
local session = require("nvim-claude.session")
local ui = require("nvim-claude.ui")
local models = require("nvim-claude.models")

local M = {}

local ns = api.nvim_create_namespace("nvim-claude")
local hl_ns = api.nvim_create_namespace("nvim-claude-target")
local remembered = {} -- bufnr -> extmark id of the last edited / asked-about range
local last_action = nil -- { kind = "ask_sel" | "replace" | "generate", buf = n }
local active = nil -- { req = id, op = "...", target = {...} }
M.skipped_keys = {}

local notify = bridge.notify

-- ---------------------------------------------------------------------------
-- Output punctuation policy
-- ---------------------------------------------------------------------------

local PUNCT = {
  ["\226\128\148"] = "-", -- em dash
  ["\226\128\147"] = "-", -- en dash
  ["\226\128\152"] = "'",
  ["\226\128\153"] = "'",
  ["\226\128\156"] = '"',
  ["\226\128\157"] = '"',
  ["\226\128\166"] = "...",
  ["\194\160"] = " ", -- non-breaking space
}

local function normalize(text)
  local mode = session.state.watermarks
  if mode == "allow" or not text then
    return text
  end
  for from, to in pairs(PUNCT) do
    text = text:gsub(from, mode == "replace" and to or "")
  end
  return text
end

-- ---------------------------------------------------------------------------
-- Targets
-- ---------------------------------------------------------------------------

local function line_len(buf, row)
  return #(api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or "")
end

local function make_mark(buf, sr, sc, er, ec)
  return api.nvim_buf_set_extmark(buf, ns, sr, sc, {
    end_row = er,
    end_col = ec,
    right_gravity = false,
    end_right_gravity = true,
    invalidate = true,
  })
end

local function mark_range(buf, id)
  if not (id and api.nvim_buf_is_valid(buf)) then
    return nil
  end
  local m = api.nvim_buf_get_extmark_by_id(buf, ns, id, { details = true })
  if not m or #m == 0 or m[3].invalid then
    return nil
  end
  return m[1], m[2], m[3].end_row or m[1], m[3].end_col or m[2]
end

local function range_text(buf, sr, sc, er, ec)
  return table.concat(api.nvim_buf_get_text(buf, sr, sc, er, ec, {}), "\n")
end

local function segment(buf, id, sr, sc, er, ec)
  return { id = id, mark = make_mark(buf, sr, sc, er, ec), row = sr, text = range_text(buf, sr, sc, er, ec) }
end

-- Capture the current (or last) Visual selection as a target.
local function capture_visual()
  local buf = api.nvim_get_current_buf()
  local mode = vim.fn.mode()
  local vpos, cpos
  if mode == "v" or mode == "V" or mode == "\22" then
    vpos, cpos = vim.fn.getpos("v"), vim.fn.getpos(".")
    api.nvim_feedkeys(api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
  else
    mode = vim.fn.visualmode()
    vpos, cpos = vim.fn.getpos("'<"), vim.fn.getpos("'>")
    if vpos[2] == 0 or cpos[2] == 0 or mode == "" then
      return nil
    end
  end
  local t = { buf = buf, segments = {}, mode = mode }
  if mode == "V" then
    local sr, er = math.min(vpos[2], cpos[2]) - 1, math.max(vpos[2], cpos[2]) - 1
    t.linewise = true
    t.segments[1] = segment(buf, "t0", sr, 0, er, line_len(buf, er))
    return t
  end
  local regions = vim.fn.getregionpos(vpos, cpos, { type = mode, exclusive = vim.o.selection == "exclusive" })
  if #regions == 0 then
    return nil
  end
  local function clamp(row, col)
    return math.max(0, math.min(col, line_len(buf, row)))
  end
  if mode == "v" then
    local first, last = regions[1][1], regions[#regions][2]
    local sr, er = first[2] - 1, last[2] - 1
    t.segments[1] = segment(buf, "t0", sr, clamp(sr, first[3] - 1), er, clamp(er, last[3]))
  else
    t.blockwise = true
    for i, r in ipairs(regions) do
      local row = r[1][2] - 1
      local sc, ec = clamp(row, r[1][3] - 1), clamp(row, r[2][3])
      if ec < sc then
        ec = sc
      end
      t.segments[#t.segments + 1] = segment(buf, "t" .. (i - 1), row, sc, row, ec)
    end
  end
  return t
end

local function forget(buf)
  local r = remembered[buf]
  if r then
    pcall(api.nvim_buf_del_extmark, buf, ns, r.mark)
  end
  remembered[buf] = nil
end

-- Remember a range plus the texts it may legitimately hold (the new text, and
-- the text it replaced, which comes back after an undo).
local function remember(buf, sr, sc, er, ec, texts)
  forget(buf)
  remembered[buf] = { mark = make_mark(buf, sr, sc, er, ec), sr = sr, sc = sc, texts = texts }
end

local function end_of(sr, sc, text)
  local lines = vim.split(text, "\n", { plain = true })
  if #lines == 1 then
    return sr, sc + #lines[1]
  end
  return sr + #lines - 1, #lines[#lines]
end

-- Re-read a remembered range as a fresh target. Undo/redo can leave the
-- extmark sized for a different text; re-anchor on a known text at the same
-- start, or forget the target rather than edit a plausible but wrong range.
local function capture_remembered(buf)
  local r = remembered[buf]
  if not r then
    return nil
  end
  local sr, sc, er, ec = mark_range(buf, r.mark)
  if not sr then
    -- Undo invalidates a mark whose text was replaced; retry where it started.
    sr, sc = r.sr, r.sc
    er, ec = sr, sc
  end
  local current = range_text(buf, sr, sc, er, ec)
  for _, text in ipairs(r.texts) do
    if current == text then
      return { buf = buf, segments = { segment(buf, "t0", sr, sc, er, ec) } }
    end
  end
  local last = api.nvim_buf_line_count(buf) - 1
  for _, text in ipairs(r.texts) do
    local ter, tec = end_of(sr, sc, text)
    if ter <= last and tec <= line_len(buf, ter) and range_text(buf, sr, sc, ter, tec) == text then
      remember(buf, sr, sc, ter, tec, r.texts)
      return { buf = buf, segments = { segment(buf, "t0", sr, sc, ter, tec) } }
    end
  end
  forget(buf)
  return nil
end

local function capture_cursor()
  local buf = api.nvim_get_current_buf()
  local pos = api.nvim_win_get_cursor(0)
  local row, col = pos[1] - 1, pos[2]
  return { buf = buf, generate = true, segments = { segment(buf, "t0", row, col, row, col) } }
end

local function highlight(t)
  if not t then
    return
  end
  for _, s in ipairs(t.segments) do
    local sr, sc, er, ec = mark_range(t.buf, s.mark)
    if sr then
      if t.generate then
        pcall(api.nvim_buf_set_extmark, t.buf, hl_ns, sr, sc, { virt_text = { { "▍", "Search" } }, virt_text_pos = "inline" })
      else
        pcall(api.nvim_buf_set_extmark, t.buf, hl_ns, sr, sc, { end_row = er, end_col = ec, hl_group = "Visual" })
      end
    end
  end
end

local function unhighlight(t)
  if t and api.nvim_buf_is_valid(t.buf) then
    api.nvim_buf_clear_namespace(t.buf, hl_ns, 0, -1)
  end
end

local function drop_marks(t)
  if not (t and api.nvim_buf_is_valid(t.buf)) then
    return
  end
  for _, s in ipairs(t.segments) do
    pcall(api.nvim_buf_del_extmark, t.buf, ns, s.mark)
  end
end

-- ---------------------------------------------------------------------------
-- Request payload
-- ---------------------------------------------------------------------------

local function buffer_context(buf, row)
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  local tick = api.nvim_buf_get_changedtick(buf)
  local convo = session.convo
  local seen = convo and convo.seen[buf]
  if seen and seen.tick == tick then
    return { kind = "unchanged" }
  end
  local limit = config.options.context_lines
  if #lines > limit then
    local s = math.max(0, row - math.floor(limit / 2))
    local e = math.min(#lines, s + limit)
    return {
      kind = "excerpt",
      start_line = s + 1,
      end_line = e,
      total_lines = #lines,
      text = table.concat(vim.list_slice(lines, s + 1, e), "\n"),
    }
  end
  local text = table.concat(lines, "\n") .. "\n"
  local baseline = { tick = tick, text = text }
  if seen and seen.text then
    local ok, d = pcall(vim.text.diff, seen.text, text, { ctxlen = 2 })
    if ok and type(d) == "string" and #d < #text then
      return { kind = "diff", text = d }, baseline
    end
  end
  return { kind = "snapshot", text = text }, baseline
end

local function surrounding(buf, row, col)
  local before_rows = api.nvim_buf_get_text(buf, math.max(0, row - 3), 0, row, col, {})
  local last = api.nvim_buf_line_count(buf) - 1
  local end_row = math.min(last, row + 3)
  local after_rows = api.nvim_buf_get_text(buf, row, col, end_row, line_len(buf, end_row), {})
  return table.concat(before_rows, "\n"), table.concat(after_rows, "\n")
end

local function build_payload(op, instruction, t)
  local payload = { operation = op, instruction = instruction }
  local baseline
  if t then
    local name = api.nvim_buf_get_name(t.buf)
    payload.document = {
      name = name ~= "" and vim.fn.fnamemodify(name, ":t") or "[No Name]",
      filetype = vim.bo[t.buf].filetype,
    }
    payload.context, baseline = buffer_context(t.buf, t.segments[1].row)
    payload.targets = {}
    for _, s in ipairs(t.segments) do
      local entry = { id = s.id, text = s.text }
      if t.generate then
        local sr, sc = mark_range(t.buf, s.mark)
        entry.before, entry.after = surrounding(t.buf, sr, sc)
      end
      payload.targets[#payload.targets + 1] = entry
    end
    if t.blockwise then
      payload.note = "Blockwise selection: one target per row. Replacements must not contain newlines."
    end
  end
  return vim.json.encode(payload), baseline
end

-- ---------------------------------------------------------------------------
-- Applying results
-- ---------------------------------------------------------------------------

local function decode(text)
  local s = vim.trim(text or "")
  s = s:match("^```[%w_-]*\n(.*)\n```$") or s
  local ok, obj = pcall(vim.json.decode, s, { luanil = { object = true, array = true } })
  if ok and type(obj) == "table" then
    return obj
  end
  local a, b = s:find("{", 1, true), s:match(".*()}")
  if a and b and b > a then
    ok, obj = pcall(vim.json.decode, s:sub(a, b), { luanil = { object = true, array = true } })
    if ok and type(obj) == "table" then
      return obj
    end
  end
end

local function show_unapplied(reason, texts)
  ui.answer("nvim-claude: not applied", reason .. "\n\n" .. table.concat(texts, "\n\n---\n\n"), true)
end

local function apply(t, raw)
  local obj = decode(raw)
  if not obj then
    return ui.answer("nvim-claude: response was not valid JSON", raw or "", true)
  end
  if obj.status == "needs_input" then
    return ui.answer("Claude needs input", obj.message or "(no message)", true)
  end
  if obj.status ~= "ok" or type(obj.replacements) ~= "table" then
    return ui.answer("nvim-claude: unexpected response", raw or "", true)
  end
  local by_id, texts = {}, {}
  for _, r in ipairs(obj.replacements) do
    if type(r) == "table" and type(r.id) == "string" and type(r.text) == "string" then
      if by_id[r.id] then
        return ui.answer("nvim-claude: duplicate target in response", raw, true)
      end
      by_id[r.id] = normalize(r.text)
      texts[#texts + 1] = by_id[r.id]
    end
  end
  local edits = {}
  for _, s in ipairs(t.segments) do
    local text = by_id[s.id]
    if not text then
      return ui.answer("nvim-claude: response missed a target", raw, true)
    end
    if t.blockwise and text:find("\n") then
      return show_unapplied("Blockwise replacement contained a newline.", texts)
    end
    if t.linewise and text:sub(-1) == "\n" then
      text = text:sub(1, -2)
    end
    local sr, sc, er, ec = mark_range(t.buf, s.mark)
    if not sr then
      return show_unapplied("The target was deleted while Claude was working.", texts)
    end
    if range_text(t.buf, sr, sc, er, ec) ~= s.text then
      return show_unapplied("The target text changed while Claude was working.", texts)
    end
    edits[#edits + 1] = { sr = sr, sc = sc, er = er, ec = ec, text = text }
  end
  if not vim.bo[t.buf].modifiable then
    return show_unapplied("The buffer is not modifiable.", texts)
  end
  table.sort(edits, function(a, b)
    return a.sr > b.sr or (a.sr == b.sr and a.sc > b.sc)
  end)
  -- Setting 'undolevels' closes the current undo block, so this edit becomes its
  -- own undo step; the set_text calls below then join into that single step.
  vim.bo[t.buf].undolevels = vim.bo[t.buf].undolevels
  for _, e in ipairs(edits) do
    api.nvim_buf_set_text(t.buf, e.sr, e.sc, e.er, e.ec, vim.split(e.text, "\n", { plain = true }))
  end
  if #edits == 1 then
    local e = edits[1]
    local er, ec = end_of(e.sr, e.sc, e.text)
    remember(t.buf, e.sr, e.sc, er, ec, { e.text, t.segments[1].text })
  end
  if t.generate and edits[1] and edits[1].text == "" then
    notify("Claude returned nothing to insert")
  end
end

-- ---------------------------------------------------------------------------
-- Running a request
-- ---------------------------------------------------------------------------

local function status(text)
  vim.g.nvim_claude_status = text
  vim.schedule(function()
    api.nvim_echo({ { text or "", "Comment" } }, false, {})
  end)
  pcall(vim.cmd.redrawstatus)
end

local function short_model()
  local m = session.state.model or "default"
  return (m:gsub("^claude%-", ""))
end

local function finish_target(t, keep)
  unhighlight(t)
  if not keep then
    drop_marks(t)
  end
end

local function send(op, instruction, t)
  if active then
    notify("a request is already running (:NvClaude cancel); your prompt is in the float's undo history", vim.log.levels.WARN)
    return finish_target(t)
  end
  active = { op = op, target = t }
  highlight(t)
  local verb = ({ ask = "asking", replace = "replacing", generate = "generating" })[op]
  status(string.format("nvim-claude: %s… (%s)", verb, short_model()))
  session.prepare(function(err)
    if err then
      active = nil
      status("")
      finish_target(t)
      if err ~= "cancelled" then
        notify(err, vim.log.levels.ERROR)
      end
      return
    end
    local state = session.convo and "continuing" or "new conversation"
    session.begin(instruction)
    status(string.format("nvim-claude: %s… (%s, %s)", verb, short_model(), state))
    local prompt, baseline = build_payload(op, instruction, t)
    local streamed = ""
    if op == "ask" then
      ui.answer("Claude · " .. short_model() .. " · …", "", true)
    end
    active.req = bridge.request("query", { prompt = prompt, stream = op == "ask" }, function(qerr, res)
      local was = active
      active = nil
      status("")
      if qerr then
        finish_target(t)
        return notify(qerr, vim.log.levels.ERROR)
      end
      if res.cancelled or (was and was.cancelled) then
        finish_target(t)
        return notify("cancelled")
      end
      if res.is_error then
        finish_target(t)
        local msg = res.text or res.subtype or "request failed"
        if msg:lower():find("login") or msg:lower():find("auth") or msg:lower():find("credential") then
          msg = msg .. "\n\nRun :NvClaude login to sign in to Claude Code."
        end
        return ui.answer("nvim-claude: error", msg, true)
      end
      session.finish(res)
      if baseline and t and session.convo then
        session.convo.seen[t.buf] = baseline
      end
      local usage = string.format("%s / %s", session.fmt_k(res.context_tokens), session.fmt_k(session.state.limit))
      if op == "ask" then
        ui.answer("Claude · " .. short_model() .. " · " .. usage, normalize(res.text or streamed), false)
        finish_target(t, true)
        if t then
          local s = t.segments[1]
          local sr, sc, er, ec = mark_range(t.buf, s.mark)
          drop_marks(t)
          if sr then
            remember(t.buf, sr, sc, er, ec, { s.text })
          end
          last_action = { kind = "ask_sel", buf = t.buf }
        else
          last_action = { kind = "ask" }
        end
      else
        unhighlight(t)
        apply(t, res.text)
        drop_marks(t)
        last_action = { kind = op, buf = t.buf }
        status("nvim-claude: done (" .. usage .. ")")
      end
    end, function(ev)
      if ev.event == "delta" and ev.text then
        streamed = streamed .. ev.text
        ui.answer_append(normalize(ev.text))
      end
    end)
  end)
end

local function open_prompt(op, t, title)
  ui.prompt({
    title = title or string.format("Claude %s · %s", op, short_model()),
    on_submit = function(text)
      send(op, text, t)
    end,
    on_cancel = function()
      finish_target(t, op == "ask")
    end,
  })
  if t then
    highlight(t)
  end
end

-- ---------------------------------------------------------------------------
-- Public actions
-- ---------------------------------------------------------------------------

function M.replace(opts)
  opts = opts or {}
  local buf = api.nvim_get_current_buf()
  local mode = vim.fn.mode()
  local t
  if mode == "v" or mode == "V" or mode == "\22" or opts.range then
    t = capture_visual()
  else
    t = capture_remembered(buf) or capture_visual()
  end
  if not t then
    return notify("select some text first", vim.log.levels.WARN)
  end
  if not vim.bo[buf].modifiable then
    drop_marks(t)
    return notify("buffer is not modifiable", vim.log.levels.WARN)
  end
  local sr, sc, er, ec = mark_range(buf, t.segments[1].mark)
  remember(buf, sr, sc, er, ec, { t.segments[1].text })
  open_prompt("replace", t)
end

function M.generate()
  local t = capture_cursor()
  if not vim.bo[t.buf].modifiable then
    drop_marks(t)
    return notify("buffer is not modifiable", vim.log.levels.WARN)
  end
  if vim.fn.mode():sub(1, 1) == "i" then
    vim.cmd.stopinsert()
  end
  open_prompt("generate", t)
end

function M.ask(opts)
  opts = opts or {}
  local buf = api.nvim_get_current_buf()
  local mode = vim.fn.mode()
  local t
  if mode == "v" or mode == "V" or mode == "\22" or opts.range then
    t = capture_visual()
  elseif opts.previous or (last_action and last_action.kind == "ask_sel" and last_action.buf == buf) then
    t = capture_remembered(buf)
    if not t and opts.previous then
      return notify("no previous selected-ask target in this buffer", vim.log.levels.WARN)
    end
  end
  open_prompt("ask", t, t and ("Claude ask about selection · " .. short_model()) or ("Claude ask · " .. short_model()))
end

function M.cancel()
  if not active or not active.req then
    return notify("nothing is running")
  end
  active.cancelled = true
  bridge.request("cancel", { id = active.req }, function() end)
end

function M.new()
  if active then
    return notify("cancel the running request first (:NvClaude cancel)", vim.log.levels.WARN)
  end
  session.new("new conversation", function()
    notify("new conversation")
  end)
end

function M.compact()
  if not session.convo then
    return notify("no conversation to compact")
  end
  session.compact(function(err)
    if err then
      notify(err, vim.log.levels.ERROR)
    end
  end)
end

function M.list()
  local items = session.saved()
  if #items == 0 then
    return notify("no saved conversations")
  end
  vim.ui.select(items, {
    prompt = "Resume conversation",
    format_item = function(item)
      local first = (item.first_prompt or ""):gsub("%s+", " ")
      if #first > 70 then
        first = first:sub(1, 67) .. "..."
      end
      return os.date("%y:%m:%d:%H:%M:%S", item.created or 0) .. " - " .. first
    end,
  }, function(item)
    if item then
      session.resume(item, function(err)
        if err then
          return notify(err, vim.log.levels.ERROR)
        end
        notify("resumed: " .. (item.first_prompt or ""):sub(1, 50))
      end)
    end
  end)
end

function M.info()
  local function render(ctx)
    local s, c = session.state, session.convo
    local used = (ctx and ctx.context_tokens) or (c and c.context_tokens)
    local lines = {
      "Model        " .. (s.model or "model default"),
      "Effort       " .. (s.effort or "model default"),
      "Limit        " .. (s.limit and session.fmt_k(s.limit) or "none (model default)") .. "  on limit: " .. config.options.on_limit,
      "Context      " .. (used and (session.fmt_k(used) .. (s.limit and string.format("  (%d%% of limit)", math.floor(used * 100 / s.limit)) or "")) or "-"),
      "Conversation " .. (not c and "none (next request starts one)" or (c.saved and "saved" or "ephemeral")),
      "Sticky       " .. (s.sticky and "on" or "off"),
      "Watermarks   " .. s.watermarks,
    }
    if c then
      lines[#lines + 1] = "First prompt " .. (c.first_prompt or ""):gsub("%s+", " "):sub(1, 60)
      if c.session_id then
        lines[#lines + 1] = "Session      " .. c.session_id
      end
      if c.last_used and not c.saved then
        local left = config.options.expire_minutes * 60 - (os.time() - c.last_used)
        lines[#lines + 1] = string.format("Expires in   ~%d min (estimated cache window)", math.max(0, math.floor(left / 60)))
      end
    end
    if session.last_transition then
      lines[#lines + 1] = "Last change  " .. session.last_transition
    end
    if session.system_override then
      lines[#lines + 1] = "System       modified for this session"
    end
    local i = bridge.info
    lines[#lines + 1] = ""
    lines[#lines + 1] = i and string.format("SDK %s · %s · Python %s", i.sdk_version or "?", i.cli_version or "?", i.python or "?")
      or "Bridge not started yet"
    if #M.skipped_keys > 0 then
      lines[#lines + 1] = "Kept your existing mappings for: " .. table.concat(M.skipped_keys, ", ")
    end
    ui.answer("nvim-claude info", table.concat(lines, "\n"), true)
  end
  if bridge.running() and session.convo and not active then
    bridge.request("context", {}, function(_, ctx)
      render(ctx)
    end)
  else
    render(nil)
  end
end

function M.system(arg)
  if arg == "default" then
    session.system_override = nil
    return notify("system prompt reset to the shipped default (applies to the next request)")
  end
  local buf = api.nvim_create_buf(false, false)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "markdown"
  pcall(api.nvim_buf_set_name, buf, "nvim-claude://system-prompt")
  api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(session.system_prompt(), "\n", { plain = true }))
  vim.bo[buf].modified = false
  api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      session.system_override = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      vim.bo[buf].modified = false
      notify("system prompt updated for this Neovim session (applies to the next request)")
    end,
  })
  vim.cmd("botright split")
  api.nvim_win_set_buf(0, buf)
end

function M.login()
  bridge.ensure(function(err)
    if err then
      return notify(err, vim.log.levels.ERROR)
    end
    vim.cmd("botright new")
    local cmd = { bridge.cli_path(), "auth", "login" }
    if vim.fn.has("nvim-0.11") == 1 then
      vim.fn.jobstart(cmd, { term = true })
    else
      vim.fn.termopen(cmd)
    end
    vim.cmd.startinsert()
  end)
end

function M.update()
  if active then
    return notify("cancel the running request first", vim.log.levels.WARN)
  end
  bridge.upgrade(function(err)
    if err then
      return notify(err, vim.log.levels.ERROR)
    end
    session.convo = session.convo and session.convo.saved and session.convo or nil
    notify("SDK upgraded; the bridge restarts on the next request")
  end)
end

-- ---------------------------------------------------------------------------
-- Commands and mappings
-- ---------------------------------------------------------------------------

local subcommands = {
  replace = function(a)
    M.replace({ range = a.range > 0 })
  end,
  ask = function(a)
    if a.fargs[2] == "previous" then
      return M.ask({ previous = true })
    end
    M.ask({ range = a.range > 0 })
  end,
  generate = function()
    M.generate()
  end,
  model = function(a)
    local expr = table.concat(vim.list_slice(a.fargs, 2), " ")
    if expr ~= "" then
      return models.apply_expression(expr)
    end
    models.pick()
  end,
  clear = function()
    M.new()
  end,
  new = function()
    M.new()
  end,
  save = function()
    session.save()
  end,
  sticky = function(a)
    local v = a.fargs[2]
    session.set_sticky(v == "on" and true or v == "off" and false or nil)
  end,
  compact = function()
    M.compact()
  end,
  list = function()
    M.list()
  end,
  info = function()
    M.info()
  end,
  cancel = function()
    M.cancel()
  end,
  system = function(a)
    M.system(a.fargs[2])
  end,
  watermarks = function(a)
    local v = a.fargs[2]
    if v ~= "allow" and v ~= "remove" and v ~= "replace" then
      return notify("watermarks: " .. session.state.watermarks .. " (allow | remove | replace)")
    end
    session.state.watermarks = v
    session.persist()
    notify("watermarks " .. v)
  end,
  update = function()
    M.update()
  end,
  login = function()
    M.login()
  end,
  log = function()
    vim.cmd("botright split " .. vim.fn.fnameescape(bridge.log_path()))
  end,
}

local subargs = {
  sticky = { "on", "off" },
  system = { "modify", "default" },
  watermarks = { "allow", "remove", "replace" },
  ask = { "previous" },
}

local function command(a)
  local name = a.fargs[1] or "info"
  local fn = subcommands[name]
  if not fn then
    return notify("unknown subcommand: " .. name, vim.log.levels.ERROR)
  end
  fn(a)
end

local function complete(arglead, line)
  local words = vim.split(line, "%s+", { trimempty = true })
  local n = #words + (line:match("%s$") and 1 or 0)
  local pool
  if n <= 2 then
    pool = vim.tbl_keys(subcommands)
  elseif words[2] == "model" then
    pool = models.slugs()
  else
    pool = subargs[words[2]] or {}
  end
  table.sort(pool)
  return vim.tbl_filter(function(s)
    return s:sub(1, #arglead) == arglead
  end, pool)
end

local ACTIONS = {
  replace = { { "n", "x" }, M.replace, "Claude: replace selection" },
  replace_short = { { "n", "x" }, M.replace, "Claude: replace selection" },
  ask = { { "n", "x" }, M.ask, "Claude: ask" },
  generate = { "n", M.generate, "Claude: generate at cursor" },
  generate_insert = { "i", M.generate, "Claude: generate at cursor" },
  model = { "n", models.pick, "Claude: pick model" },
  model_manual = { "n", models.manual, "Claude: enter model expression" },
  clear = { "n", M.new, "Claude: clear conversation" },
  new = { "n", M.new, "Claude: new conversation" },
  sticky = { "n", function() session.set_sticky() end, "Claude: toggle sticky" },
  save = { "n", session.save, "Claude: save conversation" },
  info = { "n", M.info, "Claude: info" },
  list = { "n", M.list, "Claude: resume saved conversation" },
}

local mapped = {} -- { mode, lhs } we created, so repeated setup can remove them

local function map_keys(user_keys)
  for _, m in ipairs(mapped) do
    pcall(vim.keymap.del, m[1], m[2])
  end
  mapped = {}
  M.skipped_keys = {}
  local keys = config.options.keys
  if keys == false then
    return
  end
  for name, spec in pairs(ACTIONS) do
    local lhs = keys[name]
    if type(lhs) == "string" and lhs ~= "" then
      local explicit = type(user_keys) == "table" and type(user_keys[name]) == "string"
      local modes = type(spec[1]) == "table" and spec[1] or { spec[1] }
      for _, mode in ipairs(modes) do
        local existing = vim.fn.maparg(lhs, mode, false, true)
        if not explicit and existing and existing.lhs and not (existing.desc or ""):match("^Claude:") then
          M.skipped_keys[#M.skipped_keys + 1] = mode .. " " .. lhs
        else
          vim.keymap.set(mode, lhs, spec[2], { desc = spec[3], silent = true })
          mapped[#mapped + 1] = { mode, lhs }
        end
      end
    end
  end
end

local group = api.nvim_create_augroup("nvim-claude", { clear = true })

function M.setup(opts)
  opts = opts or {}
  config.setup(opts)
  session.load()
  api.nvim_create_user_command("NvClaude", command, {
    nargs = "*",
    range = true,
    complete = complete,
    desc = "nvim-claude",
    force = true,
  })
  map_keys(opts.keys)
  api.nvim_clear_autocmds({ group = group })
  api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      bridge.stop()
    end,
  })
  api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(ev)
      remembered[ev.buf] = nil
      if session.convo then
        session.convo.seen[ev.buf] = nil
      end
    end,
  })
end

M._internal = { decode = decode, normalize = normalize, capture_visual = capture_visual }

return M
