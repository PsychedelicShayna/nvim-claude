vim.opt.runtimepath:append(vim.fn.getcwd())
require('nvim-claude').setup({ keys = false })
local origin = vim.api.nvim_get_current_win()
vim.cmd('NvClaude ask')
local prompt_win = vim.api.nvim_get_current_win()
local prompt_buf = vim.api.nvim_get_current_buf()
assert(prompt_win ~= origin and vim.api.nvim_win_get_config(prompt_win).relative == 'editor')
local title = vim.api.nvim_win_get_config(prompt_win).title
assert(type(title) == 'table' and title[1][1]:find('ask', 1, true))
local insert_keys = vim.api.nvim_buf_get_keymap(prompt_buf, 'i')
local normal_keys = vim.api.nvim_buf_get_keymap(prompt_buf, 'n')
local function mapped(keys, lhs)
  for _, item in ipairs(keys) do if item.lhs == lhs then return true end end
  return false
end
assert(mapped(insert_keys, '<C-S>') and mapped(normal_keys, '<C-S>'))
assert(mapped(normal_keys, '<CR>') and mapped(normal_keys, '<Esc>'))
local escape = vim.api.nvim_replace_termcodes('<Esc><Esc>', true, false, true)
vim.api.nvim_feedkeys(escape, 'xt', false)
assert(vim.wait(1000, function() return not vim.api.nvim_win_is_valid(prompt_win) end),
  'Normal-mode Escape should dismiss the prompt')
assert(vim.api.nvim_get_current_win() == origin, 'prompt close should restore origin focus')
print('prompt keys and focus restoration passed')
