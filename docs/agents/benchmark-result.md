# Sol low / NeoPi benchmark result

## Identity

- Model: `openai-codex/gpt-6-sol`; operator-selected reasoning effort: low.
- Harness: NeoPi. This run did not expose a harness version.
- Pinned nightly seed: `c1cf1e11bb0e9768c4d62a5cfca1a39fc49789e3`.
- Launcher baseline: `4c85985bf31be8a0ca03fe0cdc345708479d4f4c`.
- Candidate branch: `experimental/benchmark-sol-6-low-neopi-20261021T164632Z-fededfe3`.
- Worktree created: 2026-10-21 16:46:32 UTC.
- Same-model helpers: none. No other candidate source or worktree was consulted.

## Runtime and verification

- Local Neovim: 0.12.4. Probe Python: 3.14.6. Latest SDK resolved at installation: `claude-agent-sdk` 0.2.170. Its bundled Claude Code was 2.1.306. A later first-use installation may resolve a newer release.
- The bundled CLI's `auth status` reported a logged-in `claude.ai` account with a Max subscription. This observation does not establish eligibility for third-party distribution.
- Real SDK initialization announced a model catalogue with model IDs, resolved models and supported effort levels. Its context-usage control returned measured occupied tokens. A no-tools Haiku request completed and its initialization event exposed no model tools.
- A real Haiku ask through the framed Python bridge returned `ready`. A second session answered `alpha`, was saved, then resumed in a new bridge process; a follow-up recalled `alpha`. The bundled `/compact` command completed on that short saved session, but a short conversation does not demonstrate meaningful summary preservation under a full context.
- A large 81,000-byte instruction was refused by the local 100k budget guard before a model request. This proves the refusal boundary, not a strict upstream pricing ceiling.
- `tests/setup.lua`, `tests/targets.lua`, `tests/visual.lua`, `tests/block.lua` and `tests/ui.lua` passed in Neovim headless runs. They check default/overridden/disabled mappings, extmark movement, stale edits, visual replacement including exclusive selection, blockwise tab-cell preservation, remembered replacement, one-step undo and retrieving a result after its float closes.
- The published branch was installed through lazy.nvim into an isolated XDG profile, and a fresh Neovim process confirmed commands, default mappings, asynchronous SDK setup, runtime models and versions. A local-worktree editor run submitted a prompt with Ctrl-S to a real Haiku ask and kept the source unchanged. Another run generated `light` at a captured insertion boundary and applied it to the original buffer.
- The bundled runtime login command is exposed through `:NvClaude login`; no fresh login was performed because an account was already authenticated. A saved SDK session accepted a changed custom system prompt on its next turn, retained its session ID, and answered `ALPHA ready`. A full 100k accumulated-context/compaction boundary remains unexercised.

## Limitations and implementation decisions

- The SDK does not provide an exact pre-dispatch count of history plus all runtime-added prompt content. The implementation uses occupied context, input UTF-8 bytes and a 20k-token reserve, compacts early and refuses near the local limit. The local guard is **not** a proven hard 100k ceiling; `info` labels it unverified. The spec's strict-ceiling criterion remains unmet.
- The bridge limits built-in tools with `tools=[]`, isolates settings and MCP configuration, rejects any init event that announces model tools, and disables automatic IDE attachment and memory through documented runtime switches. Managed policy and runtime behavior outside these observed controls remain external.
- Conversations store SDK session IDs in a plugin-owned state manifest. Saved sessions resume without replaying a reconstructed conversation. The bridge removes exact unsaved local transcripts that it owns at clean shutdown, expiry or explicit replacement, and checks abandoned records on startup. It does not claim provider-side erasure or enumerate undocumented CLI sidecars.
- Lua owns floats, mappings, buffers and extmarks; Python owns session lifecycle and streaming SDK messages. The input and edit envelopes use JSON rather than interpolated markup. Edit application checks target text before touching the buffer and retains a failed result in a float.
- The published branch is a benchmark candidate, not a merge authorization. Gaps above are intentional disclosure of unmet acceptance, not evidence of passing behavior.

## Reproducible source size

`wc -l lua/nvim-claude/*.lua python/*.py resources/system.txt` reports 1,184 lines: Lua 744, Python 417, static prompt 23. `tests/*.lua` adds 95 lines and is excluded from the source count. Generated files and README are excluded. Fewer lines alone do not establish maintainability; target handling and explicit SDK/session boundaries account for most of this implementation.
