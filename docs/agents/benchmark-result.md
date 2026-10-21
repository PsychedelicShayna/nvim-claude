# Benchmark result

## Run identity

- Model: `openai-codex/gpt-5.6-sol`
- Selected reasoning effort: `high`
- Harness: NeoPi
- Harness version: not reported by the session
- Benchmark baseline: `4c85985bf31be8a0ca03fe0cdc345708479d4f4c`
- Pinned nightly seed: `c1cf1e11bb0e9768c4d62a5cfca1a39fc49789e3`
- Candidate branch: `experimental/benchmark-sol-5-6-high-neopi-20261021T164631Z-524e9790`
- Started: `2026-10-21T16:46:31Z`
- Completed: `2026-10-21T17:26:05Z`
- Same-model helpers: none

## Delivered implementation

This candidate is an installable Lua/Python Neovim plugin. Lua owns mappings, cursor-local prompt and answer floats, extmark-backed targets, document baselines, and editor mutations. A framed JSON-RPC bridge owns the official Python Claude Agent SDK client, session manifests, budgeting, compaction, cancellation, and runtime metadata.

The first backend command asynchronously creates a plugin-owned virtual environment and installs the latest released `claude-agent-sdk`. Normal startup reuses it; `:NvClaude update` is the explicit upgrade path. Provisioning uses a cross-process lock and atomic ready marker. Model execution disables built-in tools, allowed tools, MCP servers, setting sources, skills, agents, and plugins, then checks the runtime context for unexpected model-visible capabilities.

Selection and insertion targets use byte-indexed extmarks. Characterwise, linewise, reversed, multibyte, wide-character, partial-tab, virtual-column, and short-line block selections are handled without changing the source before a complete validated response arrives. All target edits are grouped as one undo step. Follow-ups use the extmark around the text actually inserted by the prior successful edit.

Conversations retain exact SDK session IDs. Unsaved SDK transcripts created by this plugin are removed on expiry, replacement, clean shutdown, or abandoned-instance recovery; saved sessions remain resumable. The plugin never sweeps unrelated Claude sessions. System-prompt changes reconnect to the same SDK session with a non-snapshotted replacement prompt.

## Resolved runtime

- Neovim: `0.12.4`
- Python: `3.14.6`
- Claude Agent SDK: `0.2.170`
- Bundled Claude Code: `2.1.306`
- Authentication observed: `firstParty subscription (Claude Max)`
- Live test model: `claude-haiku-5-5`, effort `low`, local limit `100000`

The runtime announced model aliases, resolved model IDs, and supported effort levels. For example, `haiku` resolved to `claude-haiku-5-5` with `low`, `medium`, `high`, `xhigh`, and `max` efforts. The plugin displays only non-sensitive authentication mode metadata; it does not expose account identity.

## Verification performed

All checks used this candidate or its pushed GitHub branch. The isolated lazy.nvim installation used run-owned XDG directories on the secondary SSD and did not load the owner's Neovim profile.

- Loaded every Lua module under `nvim --clean --headless` and byte-compiled the Python bridge.
- Ran `tests/lua/run.lua`: passed mapping preservation/override/disable behavior; model-expression parsing; UTF-8, reversed, linewise, wide-character, partial-tab, virtual short-line, and blockwise targets; stale-target refusal; one-step undo; focus-changing insertion; remembered targets; baseline snapshots/diffs; and explicit punctuation normalization.
- Ran `tests/python/test_bridge.py`: 5/5 passed for conservative refusal, pre-dispatch automatic compaction policy, no-tools SDK options and custom prompt replacement, runtime model metadata parsing, and abandoned-instance transcript ownership.
- Installed the pushed branch through lazy.nvim with `main = "nvim-claude"` and no local `dir` override. Verified commands and default, overridden, and disabled mappings in a fresh process.
- Provisioned the plugin-owned environment on first backend use. The clean-install smoke probe reported SDK `0.2.170`, bundled CLI `2.1.306`, and Python `3.14.6`.
- Sent a real general Haiku request and received the requested response.
- Exercised the actual Neovim selection-replacement interaction through `<leader>cc`; the source changed only after completion and one undo restored it.
- Saved a real SDK conversation, restarted Neovim, resumed the exact session ID, replaced the system prompt for the next request, and received the retained private test token with the new prompt prefix.
- Queried live runtime model metadata and verified announced effort levels and resolved IDs.
- Queried live runtime context after connection and verified empty tools, allowed tools, MCP servers, setting sources, skills, agents, and plugins with strict MCP configuration.
- Ran real manual compaction successfully. Automatic compaction and refusal boundaries were covered by deterministic bridge policy tests; a real 100k-bound oversized request was refused before model dispatch.
- Canceled a real request immediately after submission and received JSON-RPC cancellation code `-32800` without applying a partial result.
- Rebuilt the installed SDK environment through the explicit update path and verified the new Python executable and ready marker.

## Limitations and conservative choices

- Compatibility was exercised on Neovim `0.12.4` and Python `3.14.6`; the documented minimums of Neovim 0.10 and Python 3.10 were not separately installed during this run.
- The authenticated runtime checks used the already available Claude Max session. The delegated bundled login command is implemented but was not invoked because that would disturb the owner's working authentication. API-key and unauthenticated error modes were not exercised live.
- Real manual compaction passed, but a long live conversation was not inflated to the automatic threshold. The automatic decision, post-compaction recheck, and refusal paths were tested with controlled runtime usage responses.
- Request budgeting intentionally treats UTF-8 bytes as a conservative token upper bound and reserves configurable runtime/output allowances. It can refuse unusual byte-heavy input that might fit under a tokenizer-exact count; it will not silently exceed the selected local limit.
- The SDK is deliberately latest-on-first-setup. These exact SDK and CLI versions describe this run, not a permanent dependency pin.

## Source size

At delivered implementation commit `4c1d41b4670ebd211dfb703b55f56db8abd8cd23` before this result-only finalization:

- Product source and static prompt: 2,779 lines (`wc -l lua/nvim-claude/*.lua python/nvim_claude_bridge.py resources/system_prompt.txt`)
- Focused tests: 297 lines (`wc -l tests/lua/run.lua tests/python/test_bridge.py`)
- Counts exclude README, changelog, policy/specification documents, Git metadata, virtual environments, caches, and scratch probes.

The implementation is intentionally split by responsibility rather than compressed for the benchmark. The largest files are the Python lifecycle/session bridge and the Lua controller/target engine; neither is generated. Fewer lines would not by itself improve the state, geometry, or lifecycle guarantees exercised above.
