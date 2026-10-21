local M = {}
local baselines = {}
local serial, next_document = tostring((vim.uv or vim.loop).hrtime()), 0

local function snapshot(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local value = table.concat(lines, '\n')
  if vim.bo[buf].endofline then value = value .. '\n' end
  return value
end
local function document(buf)
  local id = vim.b[buf].nvim_claude_document_id
  if not id then
    next_document = next_document + 1
    id = 'buffer-' .. serial .. '-' .. next_document
    vim.b[buf].nvim_claude_document_id = id
  end
  return { id = id, filetype = vim.bo[buf].filetype,
    path = vim.api.nvim_buf_get_name(buf) }
end
function M.reset() baselines = {} end
function M.prepare(buf, target, operation, max_bytes)
  if operation == 'ask' and not target then return nil end
  local doc = document(buf)
  local now = snapshot(buf)
  local revision = vim.fn.sha256(now)
  local base = baselines[doc.id]
  local context
  if not base then
    context = { kind = 'snapshot', revision = revision, text = now }
  elseif base.revision == revision then
    context = { kind = 'unchanged', revision = revision }
  else
    local diff = vim.diff(base.text, now, { result_type = 'unified', ctxlen = 3 })
    if #diff < #now and #diff > 0 then
      context = { kind = 'diff', base_revision = base.revision, revision = revision, diff = diff }
    else
      context = { kind = 'snapshot', revision = revision, text = now }
    end
  end
  if max_bytes and #(context.text or context.diff or '') > max_bytes then
    local found = require('nvim-claude.target').inspect(target)
    if found then
      local minrow, maxrow = found[1].start[1], found[#found].finish[1]
      local total = vim.api.nvim_buf_line_count(buf)
      local lo, hi = math.max(0, minrow - 20), math.min(total, maxrow + 21)
      local excerpt = table.concat(vim.api.nvim_buf_get_lines(buf, lo, hi, false), '\n')
      context = { kind = 'excerpt', revision = revision, text = excerpt,
        first_row = lo, last_row_exclusive = hi,
        omitted_before_lines = lo, omitted_after_lines = total - hi }
    end
  end
  return { document = doc, context = context,
    confirm = function()
      if context.kind ~= 'excerpt' then baselines[doc.id] = { revision = revision, text = now }
      else baselines[doc.id] = nil end
    end }
end
function M.invalidate(doc)
  if doc then baselines[type(doc) == 'table' and doc.id or doc] = nil else M.reset() end
end
return M
