vim.opt.runtimepath:append(vim.fn.getcwd())
local plugin = require('nvim-claude')
local target = require('nvim-claude.target')
local model = require('nvim-claude.model')

plugin.setup({ keys = false })
local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(buf)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'ab中cd' })
-- Keep fixture creation outside the edit's undo history.
vim.bo[buf].undolevels = -1
vim.bo[buf].undolevels = 1000
vim.api.nvim_win_set_cursor(0, { 1, 2 })
local insertion = assert(target.insertion(buf, false))
assert(target.apply(insertion, { { id = insertion.segments[1].id, text = 'é' } }))
assert(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] == 'abé中cd')
vim.cmd('undo')
assert(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] == 'ab中cd')
target.release(insertion)

vim.api.nvim_win_set_cursor(0, { 1, 2 })
local stale = assert(target.insertion(buf, false))
vim.api.nvim_buf_set_text(buf, 0, 2, 0, 2, { 'new' })
local applied = target.apply(stale, { { id = stale.segments[1].id, text = 'unsafe' } })
assert(not applied, 'a changed insertion boundary must reject late output')
assert(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] == 'abnew中cd')
target.release(stale)

local parsed = assert(model.parse('claude-opus-4-6[1m][500k]:high', {
  model = 'claude-haiku-5-5', effort = 'low', context_limit_tokens = 100000,
}, {}))
assert(parsed.model == 'claude-opus-4-6[1m]' and parsed.effort == 'high'
  and parsed.context_limit_tokens == 500000)
parsed = assert(model.parse('claude-opus-4-6[1m]:high', parsed, {}))
assert(parsed.model == 'claude-opus-4-6[1m]' and parsed.context_limit_tokens == 500000)
print('editor target and model boundary checks passed')
