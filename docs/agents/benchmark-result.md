# Benchmark run record

- Model: `openai-codex/gpt-6-sol`
- Reasoning effort: `xhigh`
- Harness: NeoPi `npi/18.4.4`
- Baseline: `4c85985bf31be8a0ca03fe0cdc345708479d4f4c`, fast-forwarded from pinned nightly seed `c1cf1e11bb0e9768c4d62a5cfca1a39fc49789e3`
- Candidate branch: `experimental/benchmark-sol-6-xhigh-neopi-20261021T164647Z-d53d81bd`
- Start time: `2026-10-21T16:46:47Z`

## Implementation

One GPT-6 Sol xhigh helper implemented the Lua editor layer; another helper using the same model and effort implemented the Python SDK bridge. Both skipped checks during concurrent editing. This session integrated the two layers and ran focused verification.

The editor owns prompt/answer windows, keys and commands, UTF-8 byte-range extmarks, blockwise row targets, conflict-checked edits, context snapshots/diffs, output punctuation and system prompt overrides. The Python bridge owns framed stdio transport, Claude Agent SDK clients, session manifests, owned transcript retention, runtime configuration and bounded request admission. A static resource contains the model's edit contract.

## Verified locally

- `nvim --version` reported Neovim `0.12.4` on Linux. This is the editor version exercised, not a claimed minimum.
- `nvim --headless -u NONE -l tests/editor.lua` passed Unicode insertion, undo isolation, stale insertion rejection, a two-row block replacement across partially selected tab cells, one-step block undo, and native model-variant parsing.
- `nvim --headless -u NONE -l tests/prompt.lua` opened a cursor-local prompt with Insert/Normal Ctrl-S, Normal Enter and Escape mappings; Escape dismissed it and restored the source window. In a separate installed-plugin run, a Normal-mode Enter from the populated prompt submitted a real Haiku ask, returned `acknowledged`, and left the source buffer unchanged. Ctrl-S was checked as a mapping but not submitted.
- `tests/bridge.py` passed local 100k admission/refusal boundaries and saved-manifest selection using the installed SDK interpreter. The Python source also parsed under `/usr/bin/python`.
- A clean XDG profile under this run's secondary-drive scratch directory installed the pushed candidate branch via lazy.nvim. A fresh Neovim process registered `:NvClaude`, loaded default Normal and Visual bindings, replaced one key, disabled one key, disabled all keys, and asynchronously provisioned its own venv on first backend use. It reported Python `3.14.6`, SDK `0.2.170` and bundled Claude Code `2.1.306`. A second completely fresh XDG profile installed pushed code commit `41b7c415d728343325d9603bc3d8a66e5fd4056c`, matched its local HEAD, re-provisioned those versions, and completed a model-backed ask. This record's later commit changes documentation only.
- Runtime initialization announced selectors `default`, `opus`, `claude-fable-5-1[1m]`, `sonnet` and `haiku`, with no per-model effort list. `auth status` reported `claude.ai`. Actual `claude-haiku-5-5` turns with effort omitted under the 100k local limit answered general asks without modifying the source buffer. Its runtime `get_context_usage` reported `rawMaxTokens=100000`. The first final-profile smoke used the specified plugin default `low` effort; the follow-up switched away and back to Haiku to omit effort for further model calls.
- The runtime init event reported zero model tools and zero MCP servers. It still announced catalogue entries for 17 skills, two plugins and four agents, even with safe mode requested. The bridge exposes those counts rather than claiming the names disappeared; none appeared in the effective tool list. It did not exercise a tool invocation.
- A real selected edit changed only `...` in `The ... fox.` to `quick`; a follow-up on the remembered target changed it to `QUICK`. Saving and listing the conversation succeeded. After restarting Neovim, resuming its exact saved session produced an answer identifying the final sentence as `The QUICK fox.` The selected edit, diff follow-up and cross-process conversation reuse were exercised against the actual SDK, not a mock.
- After resuming that session again, `:NvClaude system modify` saved a session-only prompt marker. The next Haiku reply identified both the new marker and the earlier edited sentence, exercising prompt replacement without discarding conversation history.

## Known limits and unverified behavior

Claude Code documents a hard `CLAUDE_CODE_MAX_CONTEXT_TOKENS` window for recognized models only when `DISABLE_COMPACT=1`. The Haiku 100k turn reported the configured window, and the bridge combines it with local byte/reserve admission. This does not establish the provider's billed prompt length or test a large live prompt near the boundary. Smaller presets and unrecognized runtime variants refuse capped turns unless the runtime itself reports a window no larger than the selected limit.

`DISABLE_COMPACT=1` blocks `/compact`. A guarded compact request against the installed runtime returned no compaction boundary. The shipped bridge refuses manual or automatic compaction under a cap rather than sending an unprotected request. An uncapped model-default session has a genuine `/compact` path requiring the SDK's completion boundary, but that path was not exercised against a model. This misses the capped-compaction acceptance scenario in SPEC.md. Full skill/plugin isolation is not independently established by the init catalogue even though the effective model tool list is empty and safe mode is requested.

Ephemeral expiry over time, login through the interactive terminal, cancellation during streaming, and a model-backed blockwise edit were not exercised. The installed-code verification used the pushed source commit above, and the final record update is documentation only.

## Size and maintenance

At the pre-delivery count, source is 1,147 Lua lines, 829 Python bridge lines and 44 static prompt lines, for 2,020 lines excluding documentation and tests. Focused tests contain 112 lines. Regenerate the count with `wc -l lua/nvim-claude.lua lua/nvim-claude/*.lua python/nvim_claude/bridge.py resources/system.txt tests/*.lua tests/*.py`. The bridge remains a single large module, which keeps the protocol and session state together but is harder to review than the smaller Lua modules. Line count alone says little about correctness; guarded compaction is the important functional gap.
