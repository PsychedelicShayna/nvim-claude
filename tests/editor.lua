vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local target = require('nvim-claude.targets')
local plugin = require('nvim-claude')
local function equal(actual, expected)
  assert(vim.deep_equal(actual, expected), vim.inspect(actual) .. ' != ' .. vim.inspect(expected))
end
local function buffer(lines)
  vim.cmd('enew!')
  api.nvim_buf_set_lines(0, 0, -1, false, lines)
  return api.nvim_get_current_buf()
end
local function select(keys)
  api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), 'nx', false)
  return target.capture(api.nvim_get_current_buf(), vim.fn.mode())
end
local function escape() api.nvim_feedkeys('\27', 'nx', false) end

local b = buffer({ 'The ... brown fox', 'untouched' })
api.nvim_win_set_cursor(0, { 1, 4 })
local t = select('v2l')
escape()
equal(target.serialize(t)[1].text, '...')
-- An unrelated prefix insertion moves the target, which still owns its bytes.
api.nvim_buf_set_text(b, 0, 0, 0, 0, { 'Prefix ' })
assert(target.apply(t, { { id = t.parts[1].id, text = 'quick' } }))
equal(api.nvim_buf_get_lines(b, 0, -1, false), { 'Prefix The quick brown fox', 'untouched' })
equal(target.serialize(t)[1].text, 'quick')
vim.cmd('undo')
equal(api.nvim_buf_get_lines(b, 0, -1, false), { 'Prefix The ... brown fox', 'untouched' })

b = buffer({ 'aé世界z' })
api.nvim_win_set_cursor(0, { 1, 6 })
t = select('v2h')
escape()
equal(target.serialize(t)[1].text, 'é世界')
api.nvim_buf_set_text(b, 0, 1, 0, 3, { 'changed' })
local applied = target.apply(t, { { id = t.parts[1].id, text = 'bad' } })
assert(not applied, 'A stale target was overwritten')
equal(api.nvim_get_current_line(), 'achanged世界z')

b = buffer({ 'aéz', 'second', 'third' })
api.nvim_win_set_cursor(0, { 1, 1 })
t = select('v')
escape()
equal(target.serialize(t)[1].text, 'é')
api.nvim_win_set_cursor(0, { 1, 0 })
t = select('Vj')
escape()
equal(target.serialize(t)[1].text, 'aéz\nsecond\n')
assert(target.apply(t, { { id = t.parts[1].id, text = 'one\n' } }))
equal(api.nvim_buf_get_lines(b, 0, -1, false), { 'one', 'third' })
vim.cmd('undo')
equal(api.nvim_buf_get_lines(b, 0, -1, false), { 'aéz', 'second', 'third' })

b = buffer({ 'abcdef' })
vim.o.selection = 'exclusive'
api.nvim_win_set_cursor(0, { 1, 4 })
t = select('v2h')
escape()
equal(target.serialize(t)[1].text, 'cd')
vim.o.selection = 'inclusive'

b = buffer({ '\tfoo', '123456789' })
vim.bo[b].tabstop = 8
vim.o.virtualedit = 'block'
api.nvim_win_set_cursor(0, { 2, 2 })
t = select('<C-v>2lk')
escape()
assert(t.block)
local segments = target.serialize(t)
equal(segments[1].text, '   ')
equal(segments[2].text, '345')
local replacements = {}
for _, part in ipairs(t.parts) do replacements[#replacements + 1] = { id = part.id, text = 'X' } end
assert(target.apply(t, replacements))
equal(api.nvim_buf_get_lines(b, 0, -1, false), { '  X   foo', '12X6789' })
local remembered = target.serialize(t)
equal(remembered[1].text, 'X')
equal(remembered[2].text, 'X')
vim.cmd('undo')
equal(api.nvim_buf_get_lines(b, 0, -1, false), { '\tfoo', '123456789' })

b = buffer({ 'ab cd' })
api.nvim_win_set_cursor(0, { 1, 2 })
t = target.capture(b, nil, true)
vim.cmd('enew!')
assert(target.apply(t, { { id = t.parts[1].id, text = '  new\ntext ' } }))
equal(api.nvim_buf_get_lines(b, 0, -1, false), { 'ab  new', 'text  cd' })

b = buffer({ string.rep('界', 40) })
api.nvim_win_set_cursor(0, { 1, 60 })
t = target.capture(b, nil, true)
local unicode = target.serialize(t)[1]
equal(unicode.before, string.rep('界', 11))
equal(unicode.after, string.rep('界', 11))
local roundtrip = vim.json.decode(vim.json.encode(unicode))
equal(roundtrip.before, unicode.before)
assert(target.apply(t, { { id = t.parts[1].id, text = 'é' } }))
equal(api.nvim_buf_get_lines(b, 0, -1, false), { string.rep('界', 20) .. 'é' .. string.rep('界', 20) })

vim.g.mapleader = ' '
vim.keymap.set('n', '<leader>cc', function() end)
local user = vim.fn.maparg('<leader>cc', 'n', false, true).callback
plugin.setup({})
equal(vim.fn.maparg('<leader>cc', 'n', false, true).callback, user)
assert(vim.fn.maparg('<leader>ca', 'n') ~= '')
plugin.setup({ keys = { ask = '<leader>qa', generate = false } })
equal(vim.fn.maparg('<leader>ci', 'n'), '')
assert(vim.fn.maparg('<leader>qa', 'n') ~= '')
plugin.setup({ keys = false })
equal(vim.fn.maparg('<leader>qa', 'n'), '')
equal(vim.fn.maparg('<leader>cc', 'n', false, true).callback, user)
assert(vim.fn.exists(':NvClaude') == 2)
print('Editor target and mapping regressions passed')
vim.cmd('qa!')
