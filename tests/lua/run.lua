local root = assert(os.getenv("NVIM_CLAUDE_ROOT"))
vim.opt.runtimepath:prepend(root)
vim.g.mapleader = " "

local function equal(actual, expected, label)
  if not vim.deep_equal(actual, expected) then
    error((label or "values differ") .. "\nexpected: " .. vim.inspect(expected) .. "\nactual: " .. vim.inspect(actual))
  end
end

local config = require("nvim-claude.config")
local current = { effort = "low", context_limit_tokens = 100000 }
equal(config.parse_model_expression("claude-haiku-5-5[100k]:low", current), {
  model = "claude-haiku-5-5", effort = "low", context_limit_tokens = 100000,
}, "Haiku shorthand")
equal(config.parse_model_expression("claude-opus-4-6[1m][500k]:high", current), {
  model = "claude-opus-4-6[1m]", effort = "high", context_limit_tokens = 500000,
}, "native variant and local limit")
equal(config.parse_model_expression("vendor:model:high", current), {
  model = "vendor:model", effort = "high", context_limit_tokens = 100000,
}, "colon-bearing model")
equal(config.parse_model_expression("claude-opus-4-6[1m]:high", current), {
  model = "claude-opus-4-6[1m]", effort = "high", context_limit_tokens = 100000,
}, "recognized native variant")

vim.keymap.set("n", "<leader>cc", "<cmd>let g:nvclaude_user_map = 1<cr>")
require("nvim-claude").setup({ keys = { ask = false, replace_short = false } })
equal(vim.fn.exists(":NvClaude"), 2, "command registration")
assert(vim.fn.maparg("<leader>cc", "n"):find("nvclaude_user_map"), "default setup replaced a user mapping")
equal(vim.fn.maparg("<leader>ca", "n"), "", "disabled mapping")
require("nvim-claude").setup({ keys = { replace = "gR", replace_short = false, ask = false } })
assert(vim.fn.maparg("gR", "n") ~= "", "explicit replacement mapping was not installed")
require("nvim-claude").setup({ keys = false })
equal(vim.fn.maparg("gR", "n"), "", "repeated setup left a plugin mapping")
assert(vim.fn.maparg("<leader>cc", "n"):find("nvclaude_user_map"), "repeated setup removed a user mapping")

local target = require("nvim-claude.target")
local buf = vim.api.nvim_get_current_buf()
vim.bo[buf].modifiable = true
local function normal_mode()
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
end

vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "aébc" })
normal_mode()
vim.cmd("let &undolevels=&undolevels")
vim.api.nvim_win_set_cursor(0, { 1, 1 })
vim.cmd("normal! v2l")
local selected = assert(target.capture_visual("replace"))
local request_targets = assert(target.request_targets(selected))
equal(request_targets[1].text, "ébc", "UTF-8 Visual target")
local applied = assert(target.apply(selected, { { id = "target-0", text = "XYZ" } }))
equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "aXYZ" }, "selection replacement")
target.clear(applied)
vim.cmd("undo")
equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "aébc" }, "single-step undo")

normal_mode()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hello world" })
vim.api.nvim_win_set_cursor(0, { 1, 6 })
vim.cmd("normal! v4l")
local stale = assert(target.capture_visual("replace"))
vim.api.nvim_buf_set_text(buf, 0, 7, 0, 8, { "A" })
local valid, stale_error = target.validate(stale)
assert(not valid and stale_error:find("changed"), "target mutation was not rejected")
target.clear(stale)

normal_mode()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "012345" })
vim.api.nvim_win_set_cursor(0, { 1, 4 })
vim.cmd("normal! v3h")
local reversed = assert(target.capture_visual("replace"))
equal(assert(target.request_targets(reversed))[1].text, "1234", "reversed Visual target")
target.clear(reversed)

normal_mode()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "first", "second", "third" })
vim.cmd("let &undolevels=&undolevels")
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.cmd("normal! Vj")
local linewise = assert(target.capture_visual("replace"))
local deleted = assert(target.apply(linewise, { { id = "target-0", text = "" } }))
equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "third" }, "linewise deletion")
target.clear(deleted)
vim.cmd("undo")
equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "first", "second", "third" }, "linewise undo")


vim.opt.virtualedit = "all"
normal_mode()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "\tX", "\tY" })
vim.cmd("let &undolevels=&undolevels")
vim.cmd("normal! gg3|\022j2l")
local block = assert(target.capture_visual("replace"))
local block_targets = assert(target.request_targets(block))
equal({ block_targets[1].text, block_targets[2].text }, { "    ", "    " }, "partial-tab block target")
local block_result = assert(target.apply(block, {
  { id = "target-0", text = "A" }, { id = "target-1", text = "B" },
}))
equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "  A  X", "  B  Y" }, "partial-tab preservation")
target.clear(block_result)
vim.cmd("undo")
equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "\tX", "\tY" }, "blockwise one-step undo")

print("Lua behavior checks passed")
