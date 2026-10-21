vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.g.mapleader = " "

local plugin = require("nvim-claude")
local target = require("nvim-claude.target")

local function equal(actual, expected, label)
  if not vim.deep_equal(actual, expected) then
    error(("%s\nexpected: %s\nactual: %s"):format(label, vim.inspect(expected), vim.inspect(actual)))
  end
end

local parsed = assert(plugin.parse_model_expression("claude-haiku-5-5[100k]:low", {
  effort = "medium",
  context_limit_tokens = 90000,
}))
equal(parsed, { model = "claude-haiku-5-5", effort = "low", context_limit_tokens = 100000 }, "parses local budget")

parsed = assert(plugin.parse_model_expression("vendor:model:beta", {
  effort = "medium",
  context_limit_tokens = 90000,
}))
equal(parsed, { model = "vendor:model:beta", effort = "medium", context_limit_tokens = 90000 }, "preserves runtime colons")

parsed = assert(plugin.parse_model_expression("claude-opus-4-6[1m][limit=500k]:high", {
  effort = "low",
  context_limit_tokens = 100000,
}))
equal(parsed, { model = "claude-opus-4-6[1m]", effort = "high", context_limit_tokens = 500000 }, "preserves native variant")

vim.keymap.set("n", "<leader>ca", function() end, { desc = "user mapping" })
plugin.setup({})
equal(vim.fn.maparg("<leader>ca", "n", false, true).desc, "user mapping", "default does not replace user mapping")
plugin.setup({ keys = { ask = "<leader>ca" } })
equal(vim.fn.maparg("<leader>ca", "n", false, true).desc, "Ask Claude", "explicit key replaces user mapping")

local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_win_set_buf(0, buf)
vim.cmd("normal! iaéz")
vim.bo[buf].undolevels = -1
vim.bo[buf].undolevels = 1000
vim.api.nvim_win_set_cursor(0, { 1, 1 })
vim.cmd("normal! v")
local captured = target.capture_visual("replace")
vim.cmd("normal! \27")
equal(target.envelope_targets(captured)[1].text, "é", "captures a complete UTF-8 character")
local applied, reason = target.apply(captured, { [captured.segments[1].id] = "ö" }, function(value) return value end)
assert(applied, reason)
equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "aöz" }, "replaces exact multibyte selection")
vim.cmd.undo()
equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "aéz" }, "replacement is one undo step")

vim.api.nvim_win_set_cursor(0, { 1, 1 })
vim.cmd("normal! v")
local stale = target.capture_visual("replace")
vim.cmd("normal! \27")
vim.api.nvim_buf_set_text(buf, 0, 1, 0, 3, { "x" })
local stale_ok = target.apply(stale, { [stale.segments[1].id] = "y" }, function(value) return value end)
assert(not stale_ok, "a changed target must reject a late result")

vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "\tabc", "x\tz" })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.cmd([[execute "normal! \<C-v>j2l"]])
local block = target.capture_visual("replace")
vim.cmd("normal! \27")
local block_targets = target.envelope_targets(block)
equal({ block_targets[1].text, block_targets[2].text }, { " ab", " z" }, "block capture follows virtual columns")
local block_replacements = {}
for _, item in ipairs(block.segments) do block_replacements[item.id] = "Q" end
local block_ok, block_reason = target.apply(block, block_replacements, function(value) return value end)
assert(block_ok, block_reason)
equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "       Qc", "x      Q" }, "block replacement preserves unselected tab cells")
for _, item in ipairs(block.segments) do block_replacements[item.id] = "R" end
block_ok, block_reason = target.apply(block, block_replacements, function(value) return value end)
assert(block_ok, block_reason)
equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "       Rc", "x      R" }, "block follow-up targets only the prior replacement")

equal(plugin._normalize("a—b “c”…"), "a—b “c”…", "allow keeps punctuation")
plugin.setup({ keys = false, punctuation = "replace" })
equal(plugin._normalize("a—b “c”…"), 'a-b "c"...', "replace maps only configured punctuation")
plugin.setup({ keys = false, punctuation = "remove" })
equal(plugin._normalize("a—b é"), "ab é", "remove preserves unrelated Unicode")

print("headless behavior checks passed")
