# Benchmark run

- Model: `openai-codex/gpt-6-sol`
- Selected effort: medium
- Harness: NeoPi (version not exposed)
- Baseline: `4c85985bf31be8a0ca03fe0cdc345708479d4f4c`
- Pinned nightly seed: `c1cf1e11bb0e9768c4d62a5cfca1a39fc49789e3`
- Branch: `experimental/benchmark-sol-6-medium-neopi-20261021T164641Z-aef77442`
- Started: 2026-10-21 16:46:41 UTC

## Delivered implementation

Issue: #24. Lua handles editor state, floats, mappings, targets, and first-use setup. A single Python process owns the SDK client and session manifest. It communicates with Neovim through Content-Length framed JSON-RPC. The system prompt lives in `resources/system.txt`. The CLI gets `--tools \"\"`, `--strict-mcp-config`, and empty settings sources through the installed SDK's option translation.

Observed runtime: Python 3.14.6, `claude-agent-sdk` 0.2.170, bundled Claude Code 2.1.306. Its initialization metadata included model IDs, resolved models, and effort levels. Haiku 5.5 was announced with `low`, `medium`, `high`, `xhigh`, and `max`; `supportsThinkingOff` was false, so this run used `low` rather than claiming thinking could be disabled. `claude auth status` reported `claude.ai` for the available account. No API key was copied or used.

## Verification

- `nvim --headless -u NONE -l tests/editor.lua` passed. It covers default/overridden/disabled mappings, UTF-8 selection, extmark movement and invalidation, blockwise tab and wide-cell preservation, one-step block undo, and model-expression parsing.
- A clean XDG data/state/cache environment invoked the plugin in Neovim. Its first generate action asynchronously created the venv, installed the SDK, streamed a Haiku response, and changed `Hello world` to `Hello beautiful world` at the captured cursor boundary. The test's bridge process was stopped.
- A framed-stdio probe received the runtime catalogue and a streaming Haiku answer. Another probe saved a session, exited, resumed it in a new bridge process, and received `lapis` as a follow-up to a previous turn. The test session transcript was removed afterward.
- The bundled runtime accepted `/compact` through the SDK client. A subsequent probe observed `BLUE` after replacing the system prompt. A 90,000-byte fresh request was refused before a model request under the configured 100k local budget.
- A clean lazy.nvim installation from the published GitHub branch registered `:NvClaude`, default and overridden mappings, honored disabled mappings, and provisioned its own SDK environment asynchronously. The installed plugin did not refer to the author's worktree or private configuration.

## Limits and decisions

The 100k budget is **not a proven hard prompt-token ceiling**. The bridge combines reported prior occupancy, byte-bounded serialized input, and a 12k allowance; the SDK does not expose an authoritative pre-dispatch count of all runtime-added input. This is a refusal heuristic, not a billing guarantee. Large-input refusal and ordinary editing were exercised; accumulated-history and automatic-compaction thresholds were not exercised at 100k with paid model calls. The available runtime also announced built-in commands and agents in initialization metadata despite the no-tools flags. Tool exposure beyond the SDK's emitted `--tools \"\"` flag was not independently verified.

Unsaved transcript deletion matches plugin-recorded session UUIDs on normal exit, expiry, and startup cleanup of entries owned by dead processes. A process crash before its first successful result can leave an unrecorded runtime transcript. Prompt replacement was observed in a direct bridge probe, but preservation of preceding conversation after that replacement was not separately established. Interactive login and API-key billing were not exercised. A draft comparison PR is provenance for this candidate, not a request to merge it.

Source counts from `wc -l`: 194 Lua transport + 378 Lua UI + 180 Lua targets + 396 Python bridge = **1,148 implementation lines**. The 23-line static prompt brings shipped source to 1,171; the 76-line focused editor test brings that total to 1,247. Counts exclude README, this record, `.gitignore`, generated files, installed dependencies, and private config. These lines buy fairly clear Lua/Python ownership, but the gap in strict budget enforcement matters more than line count.
