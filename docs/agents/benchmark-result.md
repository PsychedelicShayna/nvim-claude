# Benchmark result

Status: delivered

## Run identity

- Model: `openai-codex/gpt-5.6-sol`
- Selected reasoning effort: `xhigh`
- Harness: NeoPi `npi/18.4.4`
- Benchmark baseline: `4c85985bf31be8a0ca03fe0cdc345708479d4f4c`
- Candidate branch: `experimental/benchmark-sol-5-6-xhigh-neopi-20261021T164649Z-20418304`
- Implementation head before this report: `f37347eae4acef18acaf07353798283b2b2bd314`
- Started: `2026-10-21T17:48:36Z`
- Completed: `2026-10-21T18:22:55Z`

## Delivered behavior

- Eight Lua modules own configuration, commands, keymaps, floats, targets, context snapshots and diffs, punctuation, model selection, and asynchronous RPC.
- One Python bridge owns the Claude Agent SDK client, saved sessions, streaming, cancellation, model metadata, context usage, compaction, and session-local prompt state.
- First use creates a plugin-owned virtual environment and installs the latest `claude-agent-sdk`. Provisioning is asynchronous, shared safely by concurrent Neovim instances, and records the resolved SDK and bundled CLI versions.
- Replace, generate, generate-at-cursor, selected ask, general ask, model selection, new/save/recall/compact/info, stop, update, and system-prompt commands are wired through `:NvClaude`.
- Every default mapping can be overridden or disabled. Defaults preserve pre-existing user mappings; explicit overrides replace them.
- Edit requests expose only captured targets, require exact JSON replacements, validate extmark-owned ranges before applying, and use one bottom-up buffer transaction. Blockwise edits preserve partial tab and wide-character cells.
- SDK options provide no tools, MCP servers, plugins, skills, setting sources, or subagents. The bundled Claude Code runtime never receives editor or filesystem tools.

## Runtime

- Python: `3.14.6`
- Claude Agent SDK: `0.2.170`
- Bundled Claude Code CLI: `2.1.306`
- Test model: `claude-haiku-5-5`, reasoning disabled, 100,000-token configured context limit

## Verification

- `NVIM_CLAUDE_ROOT="$PWD" nvim --headless -u NONE -l tests/lua/run.lua` passed. It covers model parsing, punctuation policies, characterwise and linewise target application, stale-target refusal, insertion points, block replacement constraints, partial tab and wide-cell preservation, context snapshot/diff/baseline behavior, prompt submission and focus restoration, hidden streaming output, and keymap ownership.
- `/home/shayna/.omp/python-env/bin/python tests/test_bridge_protocol.py` passed. It exercises framed RPC initialization and rejection of an over-budget request before any model process starts.
- An isolated lazy.nvim install cloned the published branch, ran `setup`, provisioned its runtime without a separate Claude Code installation, and reported SDK `0.2.170` plus bundled CLI `2.1.306`.
- The installed plugin opened a Visual replace prompt in Neovim, sent the selected word to real Haiku 5.5, and applied `The colour is red.` → `The colour is blue.` in the source buffer.
- A real saved session answered `ORCHID-917` after bridge restart and `session/resume`. A session-local prompt edit then changed the next answer to `SYSTEM OVERRIDE ACTIVE`. Restoring the packaged prompt and manual `/compact` both completed.
- The compacted session reported 1,658 used tokens in a 100,000-token context: 780 system-prompt tokens, 878 message tokens, a 33,000-token autocompact buffer, and 65,342 free tokens.
- Two headless Neovim instances started simultaneously against one empty data directory. Both completed first-use provisioning and initialized against the same SDK `0.2.170` environment; the temporary environment was then removed.
- Every implementation commit was signed with the agent key and checked with `git verify-commit`.

## Decisions and limitations

- The latest SDK reports no provider-native hard context ceiling for its advertised models. The bridge therefore rejects requests using a conservative UTF-8 byte upper bound plus runtime context occupancy and overhead, sets the runtime autocompaction window, and exposes manual compaction. It does not claim token-exact preflight rejection.
- Prompt replacement uses the SDK's custom prompt with `snapshot=false`; this is what makes the next resumed turn observe a changed session-local prompt.
- Prompt-cache lifetime depends on authentication mode, which the runtime does not expose. The info view labels its 300-second value as a conservative estimate rather than presenting it as provider fact.
- The clean install and interaction checks ran headlessly. They exercised actual Neovim windows, buffers, mappings, and the real SDK path, but did not produce a human visual review of float placement or colors.

## Source counts

- Lua product code: 4,326 lines
- Python bridge: 920 lines
- Static system prompt: 44 lines
- Focused checks: 368 lines
- README: 268 lines
