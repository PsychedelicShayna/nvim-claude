# Benchmark result

## Run identity

- Model: `openai-codex/gpt-5.6-sol`
- Selected reasoning effort: `low`
- Harness: NeoPi `18.4.4`
- Baseline commit: `4c85985bf31be8a0ca03fe0cdc345708479d4f4c`
- Candidate branch: `experimental/benchmark-sol-5-6-low-neopi-20261021T164631Z-8b31e6f4`
- Started: `2026-10-21T16:52:38Z`

## Resolved runtime

- Neovim: `0.12.4`
- Provisioning interpreter: Python `3.14.6`
- Claude Agent SDK: `0.2.170`
- Bundled Claude Code: `2.1.306`
- Exercised model: `claude-haiku-5-5`, effort `low`
- Authentication observed: existing first-party subscription credentials accepted by the bundled runtime. The plugin did not copy credentials or set an API key.

The runtime initialization metadata announced 13 model choices, including Haiku 5.5, and supplied per-model effort metadata. The Haiku entry announced `low`, `medium`, `high`, `xhigh`, and `max`. Context diagnostics after a real turn reported zero effective MCP tools and zero effective agents. The bridge requested `tools=[]`, `allowed_tools=[]`, empty MCP configuration with strict mode, no setting sources, no skills, no plugins, no agents, and no fallback model.

## Verification performed

- `nvim --clean --headless -u NONE '+luafile tests/lua_spec.lua' +qa!` passed. It covers model-expression parsing, punctuation policies, mapping preservation and disabling, command registration, UTF-8 selection replacement, target scope, and one-step undo.
- `python -m unittest tests/test_bridge.py` passed 5 tests in the provisioned environment. It covers explicit no-tools options, conservative refusal at a local limit, runtime occupancy parsing, catalogue provenance, and saved-list ordering.
- A clean first backend use created a plugin-owned virtual environment and installed SDK `0.2.170` without blocking Neovim's setup path. The bridge reported Python and bundled CLI versions after provisioning.
- A real general ask through the framed stdio bridge returned exactly `OK`. Runtime diagnostics reported model metadata, context occupancy, cache provenance, and no effective MCP tools or agents.
- A real visual replacement drove the default `<leader>cc` mapping, cursor-local prompt, Ctrl-S submission, edit-envelope validation, and source application. Haiku changed `teh cat` to `the cat`.
- A real saved SDK session survived a complete Neovim/bridge restart. The first process stored the codeword `amber`; the second listed and resumed the exact saved conversation, and Haiku answered `amber`. The test transcript and manifest were removed afterward by their recorded IDs.
- The pushed branch was installed into clean data/config/state/cache directories through lazy.nvim using the documented repository, branch, `main = "nvim-claude"`, and `opts = {}` entry. A fresh process saw `:NvClaude` and default mappings. Repeated setup replaced an explicitly overridden key, disabled an individual key, and provisioned a separate clean SDK environment.
- Every commit signature was checked with `git verify-commit` when created.

## Implementation choices

Lua owns prompts, answer windows, mappings, source context, extmarks, stale-target checks, output validation, punctuation presentation, and edits. Python owns provisioning, JSON-RPC framing, the SDK client, streaming, interruption, runtime metadata, request budgeting, session IDs, and the plugin manifest.

Document context starts with a snapshot or labeled excerpt. Accepted revisions become baselines for append-only unified diffs or explicit unchanged markers. Automatic or manual compaction resets Lua's baselines; if compaction happens during request admission, the bridge substitutes the fresh snapshot/excerpt carried for that purpose instead of sending a diff against summarized history.

The local ceiling uses measured runtime occupancy plus an intentionally conservative bound of one token per UTF-8 byte and a 20,000-token reserve for runtime additions and output. This can refuse requests that would fit, but it cannot undercount supplied UTF-8 bytes. The runtime also reported its 100,000-token maximum and a 67,000-token automatic compaction threshold for the exercised Haiku session.

Block selections use Neovim's `getregion()` and `getregionpos()` semantics. Partial tabs and wide characters are materialized only at affected boundaries so unselected display cells survive; segment replacements remain row-local and apply bottom-up in one undo block.

## Limitations and unverified paths

- The conservative refusal boundary was exercised locally, and the runtime's automatic-compaction threshold was observed, but a near-100,000-token paid request and a real automatic compaction were not generated. Manual `/compact` is wired to the runtime command but was not exercised against a long live conversation.
- Real cancellation, a stale target during a live response, linewise/blockwise UI gestures, and a model-backed system-prompt override were not exercised end to end. Their local state transitions and validation paths are implemented.
- The bundled login command path is exposed through `:NvClaude login`, but the interactive login flow was not run because existing supported credentials already authenticated the SDK.
- Runtime model discovery was verified for the installed version. Manual model slugs remain available when later runtimes omit catalogue metadata.
- Prompt cache TTL remains an estimate because the runtime did not announce an authoritative per-session TTL. `:NvClaude info` labels it accordingly.

## Reproducible line counts

The count command was:

```sh
wc -l lua/nvim-claude/*.lua python/nvim_claude_bridge.py resources/system-prompt.txt tests/lua_spec.lua tests/test_bridge.py
```

Product source and the static prompt total 1,471 lines: 928 Lua, 499 Python, and 44 prompt-resource lines. Focused tests add 119 lines, for 1,590 counted lines. The count excludes README, specification, policy, changelog, benchmark records, generated files, installed dependencies, and temporary verification scripts.

## Assessment

The candidate is independently installable and exercises the core user path against the real runtime. Its strongest choices are the strict separation between raw history and presentation output, conservative admission control, explicit fresh-context handoff after compaction, and ownership-scoped session cleanup. The main remaining risk is breadth: several uncommon editor transitions and long-context paths are implemented but did not receive a live end-to-end run during this benchmark.
