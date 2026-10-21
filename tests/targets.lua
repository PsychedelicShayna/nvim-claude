local api = vim.api
vim.opt.rtp:append(vim.fn.getcwd())
local T = require('nvim-claude.targets')
local function same(actual, expected) assert(vim.deep_equal(actual, expected), vim.inspect({ actual, expected })) end
local function buffer(lines)
  vim.cmd('enew!')
  api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.cmd('let &undolevels = &undolevels')
  return api.nvim_get_current_buf()
end
local function apply(t, outputs)
  local replacements = {}
  for i, p in ipairs(t.parts) do replacements[i] = { id = p.id, text = outputs[i] } end
  local updated, err = T.apply(t, replacements)
  assert(updated, err)
  return updated
end

local b = buffer({ 'The ... brown fox.', 'untouched' })
local t = T.create(b, { { start = { 0, 4 }, finish = { 0, 7 } } })
api.nvim_buf_set_lines(b, 0, 0, false, { 'prefix' })
local updated = apply(t, { 'quick' })
same(api.nvim_buf_get_lines(b, 0, -1, false), { 'prefix', 'The quick brown fox.', 'untouched' })
same(T.envelope(updated)[1].text, 'quick')
vim.cmd('undo')
same(api.nvim_buf_get_lines(b, 0, -1, false), { 'prefix', 'The ... brown fox.', 'untouched' })
assert(not T.positions(updated), 'undo must invalidate remembered output')
vim.cmd('undo')
same(api.nvim_buf_get_lines(b, 0, -1, false), { 'The ... brown fox.', 'untouched' })

b = buffer({ 'αβγ hello' })
t = T.create(b, { { start = { 0, 2 }, finish = { 0, 4 } } })
apply(t, { 'δ' })
same(api.nvim_get_current_line(), 'αδγ hello')

b = buffer({ 'selected tail' })
t = T.create(b, { { start = { 0, 0 }, finish = { 0, 8 } } })
api.nvim_buf_set_text(b, 0, 2, 0, 3, { 'X' })
local invalid = T.apply(t, { { id = t.parts[1].id, text = 'overwrite' } })
assert(not invalid)
same(api.nvim_get_current_line(), 'seXected tail')

b = buffer({ 'ab', 'cd', 'ef' })
t = T.create(b, { { start = { 0, 0 }, finish = { 1, 2 } } }, 'V')
apply(t, { 'first\nsecond\n' })
same(api.nvim_buf_get_lines(b, 0, -1, false), { 'first', 'second', 'ef' })

b = buffer({ 'abc', 'xyz' })
t = T.create(b, { { start = { 0, 1 }, finish = { 0, 2 } }, { start = { 1, 1 }, finish = { 1, 2 } } }, '\22')
apply(t, { 'BB', 'YY' })
same(api.nvim_buf_get_lines(b, 0, -1, false), { 'aBBc', 'xYYz' })
vim.cmd('undo')
same(api.nvim_buf_get_lines(b, 0, -1, false), { 'abc', 'xyz' })

b = buffer({ 'abcd' })
api.nvim_win_set_cursor(0, { 1, 2 })
t = T.insertion()
api.nvim_win_set_cursor(0, { 1, 0 })
apply(t, { ' X\nY ' })
same(api.nvim_buf_get_lines(b, 0, -1, false), { 'ab X', 'Y cd' })

b = buffer({ 'αβγ hello' })
vim.cmd.normal({ args = { 'gg02lvh' }, bang = true })
t = T.visual()
same(T.envelope(t)[1].text, 'βγ')
api.nvim_feedkeys(vim.keycode('<Esc>'), 'nx', false)
apply(t, { 'X' })
same(api.nvim_get_current_line(), 'αX hello')

b = buffer({ 'a\tbc', '12345678' })
vim.cmd.normal({ args = { vim.keycode('gg02l<C-v>j2h') }, bang = true })
t = T.visual()
api.nvim_feedkeys(vim.keycode('<Esc>'), 'nx', false)
apply(t, { 'X', 'Y' })
same(api.nvim_buf_get_lines(b, 0, -1, false), { 'a     Xc', '123456Y' })

b = buffer({ 'abcdef', 'x' })
vim.o.virtualedit = 'block'
vim.cmd.normal({ args = { vim.keycode('gg02l<C-v>j2l') }, bang = true })
t = T.visual()
api.nvim_feedkeys(vim.keycode('<Esc>'), 'nx', false)
apply(t, { 'X', 'Y' })
same(api.nvim_buf_get_lines(b, 0, -1, false), { 'abXf', 'x Y' })
vim.o.virtualedit = ''

b = buffer({ 'keep', 'delete' })
t = T.create(b, { { start = { 1, 0 }, finish = { 1, 6 } } }, 'V')
updated = apply(t, { '' })
same(api.nvim_buf_get_lines(b, 0, -1, false), { 'keep' })
same(T.envelope(updated)[1].text, '')

print('TARGET_SAFETY_OK')
vim.cmd('qa!')
