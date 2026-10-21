local root = assert(vim.env.NVIM_CLAUDE_ROOT, "NVIM_CLAUDE_ROOT is required")
vim.opt.runtimepath:prepend(root)

local function equal(actual, expected, label)
  if not vim.deep_equal(actual, expected) then
    error(string.format("%s\nexpected: %s\nactual:   %s", label, vim.inspect(expected), vim.inspect(actual)))
  end
end

local config = require("nvim-claude.config")
local context = require("nvim-claude.context")
local model = require("nvim-claude.model")
local punctuation = require("nvim-claude.punctuation")
local target = require("nvim-claude.target")

local parsed = assert(model.parse("claude-haiku-5-5[100k]:low", {}))
equal(parsed, {
  model = "claude-haiku-5-5",
  effort = "low",
  context_limit_tokens = 100000,
}, "manual model expression")

parsed = assert(model.parse("claude-opus-4-6[1m][500k]:high", {}))
equal(parsed, {
  model = "claude-opus-4-6[1m]",
  effort = "high",
  context_limit_tokens = 500000,
}, "native selector plus local limit")

parsed = assert(model.parse("provider:model:variant", {
  effort = "medium",
  context_limit_tokens = 90000,
}))
equal(parsed.model, "provider:model:variant", "arbitrary colon model")
equal(parsed.effort, "medium", "retained effort")
equal(parsed.context_limit_tokens, 90000, "retained local limit")

parsed = assert(model.parse("claude-custom[limit=124k]:xhigh", {}))
equal(parsed.model, "claude-custom", "explicit limit selector")
equal(parsed.context_limit_tokens, 124000, "explicit limit value")

equal(
  punctuation.apply("— – ‘x’ “y” … z", "replace"),
  "- - 'x' \"y\" ... z",
  "punctuation replacement"
)
equal(punctuation.apply("a—b…c", "remove"), "abc", "punctuation removal")
equal(punctuation.apply("éλ🙂", "replace"), "éλ🙂", "unlisted Unicode remains unchanged")

local merged = config.setup({ keys = { ask = false, model = "gm" } })
equal(merged.keys.ask, false, "explicit key disable")
equal(merged.keys.model, "gm", "explicit key override")
equal(merged.keys.replace, "<leader>cc", "omitted default key")

do
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { "αβγ", string.rep("z", 400), "second line" })
  vim.api.nvim_set_current_buf(bufnr)
  local selected = assert(target.capture_visual({
    bufnr = bufnr,
    mode = "v",
    anchor = { bufnr, 1, 3, 0 },
    cursor = { bufnr, 1, 3, 0 },
    operation = "replace",
  }))
  local envelope = assert(target.to_envelope(selected))
  equal(envelope[1].text, "β", "multibyte visual target")

  local prepared = assert(context.prepare(bufnr, { target = selected }))
  equal(prepared.context.kind, "snapshot", "first buffer context is a snapshot")
  assert(context.accept(prepared))
  local unchanged = assert(context.prepare(bufnr, { target = selected }))
  equal(unchanged.context.kind, "unchanged", "accepted unchanged context")

  local response = string.format('{"status":"ok","replacements":[{"id":"%s","text":"B"}]}', envelope[1].id)
  local applied = target.apply(selected, response)
  assert(applied.applied, applied.reason)
  equal(vim.api.nvim_buf_get_lines(bufnr, 0, 1, true)[1], "αBγ", "replace exact multibyte selection")

  local changed = assert(context.prepare(bufnr, { target = selected }))
  equal(changed.context.kind, "diff", "plugin output becomes an append-only diff")

  local stale = assert(target.capture_visual({
    bufnr = bufnr,
    mode = "v",
    anchor = { bufnr, 3, 1, 0 },
    cursor = { bufnr, 3, 6, 0 },
    operation = "replace",
  }))
  local stale_envelope = assert(target.to_envelope(stale))
  vim.api.nvim_buf_set_text(bufnr, 2, 0, 2, 6, { "edited" })
  local rejected = target.apply(stale, {
    status = "ok",
    replacements = { { id = stale_envelope[1].id, text = "unsafe" } },
  })
  assert(not rejected.applied, "stale target must not be overwritten")
  equal(vim.api.nvim_buf_get_lines(bufnr, 2, 3, true)[1], "edited line", "stale source text remains")

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

do
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { "abcd", "ABCD" })
  vim.api.nvim_set_current_buf(bufnr)
  local block = assert(target.capture_visual({
    bufnr = bufnr,
    mode = "\22",
    anchor = { bufnr, 1, 2, 0 },
    cursor = { bufnr, 2, 3, 0 },
    operation = "replace",
  }))
  local block_targets = assert(target.to_envelope(block))
  equal(#block_targets, 2, "block target rows")
  local invalid, invalid_error = target.decode_result(block, {
    status = "ok",
    replacements = {
      { id = block_targets[1].id, text = "x\ny" },
      { id = block_targets[2].id, text = "z" },
    },
  })
  assert(invalid == nil and invalid_error:find("newline"), "block replacement rejects newlines")
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

do
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { "hello" })
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_win_set_cursor(0, { 1, 2 })
  local insertion = assert(target.capture_insert({ bufnr = bufnr, winid = 0, mode = "n" }))
  local insertion_target = assert(target.to_envelope(insertion))[1]
  equal(insertion_target.start, { 0, 2 }, "normal insertion boundary")
  local outcome = target.apply(insertion, {
    status = "ok",
    replacements = { { id = insertion_target.id, text = "X" } },
  })
  assert(outcome.applied)
  equal(vim.api.nvim_buf_get_lines(bufnr, 0, 1, true)[1], "heXllo", "generate inserts once at captured boundary")
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

print("lua-behavior=ok")
