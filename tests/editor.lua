vim.opt.rtp:append(vim.fn.getcwd())
local plugin = require('nvim-claude')
local targets = require('nvim-claude.targets')
local b = vim.api.nvim_get_current_buf()
local function keys(input) vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(input, true, false, true), 'xt', false) end
local function current() return vim.api.nvim_buf_get_lines(b, 0, -1, false) end

plugin.setup()
assert(vim.fn.exists(':NvClaude') == 2)
assert(vim.fn.maparg('<leader>cc', 'x') ~= '')
plugin.setup({ keys = { generate = false, ask = '<leader>Q' } })
assert(vim.fn.maparg('<leader>ci', 'n') == '')
assert(vim.fn.maparg('<leader>Q', 'n') ~= '')
plugin.setup({ keys = false })
assert(vim.fn.maparg('<leader>Q', 'n') == '')

vim.api.nvim_buf_set_lines(b, 0, -1, false, { 'aébc', 'second' })
vim.api.nvim_win_set_cursor(0, { 1, 1 })
keys('v')
local selected = targets.capture('replace', true)
assert(targets.envelope(selected)[1].text == 'é')
keys('<Esc>')
assert(targets.apply(selected, { { id = 'target-0', text = 'Ω' } }))
assert(current()[1] == 'aΩbc')
assert(targets.previous(b, false))
vim.api.nvim_buf_set_text(b, 0, 0, 0, 0, { '!' })
assert(targets.previous(b, false))
vim.api.nvim_buf_set_text(b, 0, 2, 0, 4, { 'x' })
assert(not targets.previous(b, false))

vim.api.nvim_buf_set_lines(b, 0, -1, false, { '\tab', 'ab\txy' })
vim.bo[b].tabstop = 4
vim.api.nvim_win_set_cursor(0, { 1, 0 })
keys('<C-v>j')
local block = targets.capture('replace', true)
keys('<Esc>')
assert(block.block and #block.segments == 2)
local replacement = {}
for _, segment in ipairs(block.segments) do replacement[#replacement + 1] = { id = segment.id, text = 'Q' } end
assert(targets.apply(block, replacement))
assert(current()[1] == '   Qab', vim.inspect(current()))
assert(current()[2] == 'ab Qxy', vim.inspect(current()))
vim.cmd('undo')
assert(vim.deep_equal(current(), { '\tab', 'ab\txy' }), vim.inspect(current()))
assert(not targets.previous(b, false), 'Undo must invalidate the replaced target')
local backend = require('nvim-claude.backend')
local original_call, original_input = backend.call, vim.ui.input
local captured
backend.call = function(method, params, callback)
  assert(method == 'model')
  captured = params.config
  callback({ config = captured }, nil)
end
for _, case in ipairs({
  { input = 'claude-haiku-5-5[100k]:low', model = 'claude-haiku-5-5', limit = 100000, effort = 'low' },
  { input = 'claude-opus-4-6[1m][500k]:high', model = 'claude-opus-4-6[1m]', limit = 500000, effort = 'high' },
  { input = 'claude-opus-4-6[1m]:high', model = 'claude-opus-4-6[1m]', limit = 500000, effort = 'high' },
  { input = 'custom:model[limit=90k]', model = 'custom:model', limit = 90000, effort = 'high' },
}) do
  vim.ui.input = function(_, callback) callback(case.input) end
  plugin.command('model_manual')
  assert(captured.model == case.model and captured.limit == case.limit and captured.effort == case.effort,
    vim.inspect(captured))
end
backend.call, vim.ui.input = original_call, original_input
print('editor target checks passed')
