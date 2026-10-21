vim.opt.runtimepath:prepend(vim.fn.getcwd())

local function equal(actual, expected, label)
  if not vim.deep_equal(actual, expected) then
    error(('%s: expected %s, got %s'):format(label, vim.inspect(expected), vim.inspect(actual)))
  end
end

local config = require('nvim-claude.config')
local parsed = config.parse_model('claude-haiku-5-5[100k]:low', config.defaults)
equal(parsed.model, 'claude-haiku-5-5', 'budget model')
equal(parsed.context_limit_tokens, 100000, 'budget amount')
equal(parsed.effort, 'low', 'effort')
parsed = config.parse_model('claude-opus-4-6[1m][500k]:high', config.defaults)
equal(parsed.model, 'claude-opus-4-6[1m]', 'native variant')
equal(parsed.context_limit_tokens, 500000, 'second budget')
parsed = config.parse_model('vendor:model', config.defaults)
equal(parsed.model, 'vendor:model', 'colon model')

local normalize = require('nvim-claude.normalize')
equal(normalize.apply('a—b “c”…', 'replace'), 'a-b "c"...', 'punctuation replacement')
equal(normalize.apply('a—b', 'remove'), 'ab', 'punctuation removal')

vim.g.mapleader = ' '
vim.keymap.set('n', '<leader>cc', '<cmd>echo "mine"<cr>')
require('nvim-claude').setup({ keys = { generate = '<leader>z' } })
equal(vim.fn.maparg('<leader>cc', 'n'):find('mine', 1, true) ~= nil, true, 'default preserves user map')
equal(vim.fn.maparg('<leader>z', 'n') ~= '', true, 'override installed')
require('nvim-claude').setup({ keys = false })
equal(vim.fn.maparg('<leader>z', 'n'), '', 'repeat setup removes plugin map')
equal(vim.fn.exists(':NvClaude'), 2, 'command registered')

local target = require('nvim-claude.target')
local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(buf)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'héllo world' })
vim.bo[buf].undolevels = -1
vim.bo[buf].undolevels = 1000
vim.api.nvim_win_set_cursor(0, { 1, 1 })
vim.cmd('normal! v3l')
vim.api.nvim_feedkeys(vim.keycode('<Esc>'), 'x', false)
local captured = assert(target.capture('replace', true))
equal(target.payload(captured)[1].text, 'éllo', 'multibyte visual capture')
local ok, err = target.apply(captured, { { id = 'target-0', text = 'i' } })
equal({ ok, err }, { true, nil }, 'replacement applies')
equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1], 'hi world', 'replacement scope')
vim.cmd('undo')
equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1], 'héllo world', 'one undo restores edit')

print('lua-spec-ok')
