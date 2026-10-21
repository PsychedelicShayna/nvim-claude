# Sol 6 high, NeoPi benchmark run

- Model: `openai-codex/gpt-6-sol` (session metadata); reasoning effort: high.
- Harness: NeoPi, version not exposed by the session metadata.
- Baseline commit: `4c85985bf31be8a0ca03fe0cdc345708479d4f4c`.
- Pinned nightly seed: `c1cf1e11bb0e9768c4d62a5cfca1a39fc49789e3`.
- Candidate branch: `experimental/benchmark-sol-6-high-neopi-20261021T164637Z-b89c2c62`.
- Run start: 2026-10-21 16:46:37 UTC (worktree creation); implementation began after the owner's `BEGIN!` instruction.

## Delivered candidate

The Lua plugin owns selections, buffer edits, mappings, floats, and cancellation. The Python bridge owns the Claude Agent SDK, session persistence, prompt framing, and context accounting. SDK tools, plugins, skills, settings sources, and MCP servers are disabled. Its static editing prompt asks for a complete JSON replacement per target; Lua applies only validated target text and never gives Claude file-editing tools.

The Python venv is installed on first backend use, not while Neovim starts. `:NvClaude update` explicitly refreshes the SDK. A selected range is represented by extmarks and checked again before application; block rows use display columns and split partly selected tab cells rather than consuming the whole tab. Output normalization is explicit and leaves raw conversation history untouched. Saved SDK transcripts are mirrored to a local SQLite store for resumption across editor restarts; unsaved sessions are removed on exit or a later launch after an abnormal exit.

## Observed environment

- Neovim `0.12.4`; system Python `3.14.6`.
- Latest-on-install Python `claude-agent-sdk` `0.2.170`; bundled Claude Code CLI `2.1.306`.
- The isolated bundled runtime reported `apiProvider = firstParty` and `subscriptionType = Claude Max`; these are runtime account metadata, not an independent billing audit.
- Actual remote branch clone installed with lazy.nvim into a fresh, isolated XDG config/data/state/cache profile. Default, overridden, and disabled mappings, command registration, asynchronous first-use Python provisioning, and the runtime model catalogue succeeded from a fresh Neovim process.
- The bundled CLI exposes `claude auth login`; the bridge does not copy OAuth tokens or supply an API key.

## Exercised checks

- `python -m unittest discover -s tests -p test_bridge.py -v`: five passing behavioral checks for model/budget syntax, edit target validation, mandatory-input refusal and compaction margin, labeled excerpt-to-diff transition, and rejection of a failed runtime compaction without invalidating baselines.
- `nvim --headless -u NONE -l tests/targets.lua`: live Visual mapping capture, reversed multibyte selection, extmark movement and stale-result rejection, tabbed and short block rows, atomic edit validation, cursor insertion, and one-step undo passed.
- A headless Neovim visual mapping opened the real prompt float from an active Visual selection.
- A fresh installed remote branch loaded the normal lazy.nvim setup path, mapped defaults, accepted overrides and `keys=false`, installed its own venv on first use, and connected to the bundled runtime for its model catalogue.
- From that installed branch, a real `claude-haiku-5-5` request generated `swift ` at the cursor in `brown fox`, producing `swift brown fox`. Neovim undo restored `brown fox`. Authentication worked with the runtime's recognized account on this machine; billing was not independently verified.
- With tools, skills, plugins, settings sources, and MCP disabled, the runtime's context usage reported zero MCP tools, zero memory files, and zero active agents. Its server catalogue still named five built-in agent types, but no tools were exposed to invoke them; this does not establish that managed policy or every runtime hook is absent.
- A saved SDK transcript resumed in a new Python bridge process and recalled `ORBIT`. Replacing the system prompt between turns produced `ORBIT` in all caps on the next reply. Explicit `/compact` succeeded after sufficient conversation history. With too little history the runtime returned `Not enough messages to compact`; the bridge now reports that failure instead of implying a summary was created.

## Limits and maintenance notes

The 100k local budget is a conservative preflight estimate, **not** a runtime-enforced input cap or a verified Haiku pricing ceiling. The SDK exposes no per-request hard input stop. The plugin reports strict enforcement as unsupported before dispatch, refuses requests that exceed its conservative estimate, and declines to advertise the 100k ceiling as guaranteed. A real automatic-compaction threshold involving a long accumulated history was not exercised; the preflight transition and refusal boundaries were checked with deterministic occupancy inputs, while explicit runtime compaction was exercised. The runtime's own context occupancy and reported subscription/provider are displayed separately from cumulative usage; a cache TTL is an estimate, not proof of a live cache entry. Claude Code's published SDK login restriction for third-party products is called out in README.md; a personal local login is not a claim about permitted distribution or billing.

The implementation has 1,437 Lua/Python source lines (`lua/nvim-claude/{init,bridge,targets}.lua` and `python/nvim_claude_bridge.py`), 23 prompt-resource lines, and 194 focused test lines: 1,654 authored lines total from `wc -l`. This excludes README, the run record, the unchanged spec, generated environments, SDK source, and disposable smoke scripts. The code is deliberately split across editor state and SDK state, but the two language boundary and persistent transcript mirror remain real maintenance costs; fewer lines alone would not establish a better implementation.
