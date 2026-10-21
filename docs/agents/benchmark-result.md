# Benchmark result

## Run identity

- Provider/model: `openai-codex/gpt-5.6-sol`
- Selected reasoning effort: `medium`
- Harness: NeoPi `18.4.4`
- Baseline commit: `4c85985bf31be8a0ca03fe0cdc345708479d4f4c`
- Pinned nightly seed: `c1cf1e11bb0e9768c4d62a5cfca1a39fc49789e3`
- Candidate branch: `experimental/benchmark-sol-5-6-medium-neopi-20261021T164636Z-6564093c`
- Start time: `2026-10-21T16:46:36Z`
- Run issue: `#29`

No implementation subagents were used.

## Delivered behavior

The candidate is a lazy.nvim-installable Neovim plugin with:

- Cursor-local prompt and answer floats for general ask, selected ask, replacement, and generation.
- UTF-8-safe characterwise and linewise targets plus virtual-column block targets that preserve unselected tab cells.
- Extmark tracking, stale-target rejection, late-event cancellation, exact target-addressed edit envelopes, and one-step undo.
- Automatic, lock-protected virtual-environment creation and latest-release SDK installation on first backend use.
- A persistent Python SDK bridge over Content-Length-framed JSON-RPC on stdio.
- Runtime-enforced `tools=[]`, empty MCP configuration, no setting sources, skills, plugins, or agents.
- Runtime-announced model and effort selection, manual model expressions, local context budgets, proactive compaction, and request refusal.
- Snapshot, unchanged, diff, and excerpt context forms with accepted-buffer baselines.
- Ephemeral, saved, sticky, cleared, new, compacted, listed, and resumed conversations.
- Session-local system-prompt replacement and exact raw assistant history.
- Configurable mappings, output punctuation policy, runtime login delegation, SDK updates, and session diagnostics.

## Resolved runtime

| Component | Observed version |
| --- | --- |
| Neovim | `0.12.4` |
| Provisioning Python | `3.14.6` |
| Claude Agent SDK | `0.2.170` |
| Bundled Claude Code | `2.1.306` |

Runtime initialization announced 13 models with model-specific effort metadata. It reported a first-party Claude Max account, an empty MCP server list, and no model-accessible tools in the SDK initialization message. Existing supported runtime authentication was used. No credential was copied into a test environment.

## Verification

### Focused checks

```text
python -m py_compile python/nvim_claude_bridge.py
nvim --headless -u NONE -l tests/headless.lua
PYTHONPATH=. sdk-probe/bin/python -m unittest tests.test_bridge
```

All passed. The Lua check covers model-expression parsing, mapping ownership, multibyte targets, stale results, undo, partial-tab block selection, block follow-up scope, and punctuation normalization. The Python check covers conservative UTF-8 budget accounting and refusal before dispatch.

### Published installation

A clean XDG configuration bootstrapped lazy.nvim, cloned this candidate by repository and branch, called `setup({})`, and initialized the plugin-owned SDK environment. The final unpinned install resolved to `cf2006b5b7a851c7f244af4e8c8c97f1d4159669`, the candidate head before this result-only commit. It exposed `:NvClaude`, default mappings, runtime models, SDK and CLI versions, no tools, and no MCP servers.

The first clean-install script completed all plugin assertions and printed its passing result. Its wrapper later timed out because plain `:qa` refused a deliberately modified source buffer. Later install and editor checks used `:qa!` and exited normally.

### Model-backed editor behavior

Using Haiku 5.5 at low effort and the 100,000-token local budget:

- A general ask streamed `ready` into an answer float and left the source buffer unchanged.
- Visual replacement changed only `...` in `The ... fox` to `quick`.
- A Normal-mode follow-up changed the remembered `quick` target to `slow`.
- One undo restored `quick`.
- A saved conversation resumed in a second bridge process and recalled `LILAC`.
- A system-prompt override affected the next turn while preserving history, producing `OVERRIDE: COBALT`.
- Manual runtime compaction completed, and the next turn still recalled `COBALT`.
- The SDK update path stopped the old bridge, upgraded the environment, started a replacement, and answered a metadata request without the retiring process clearing the replacement.

Every probe stopped its bridge. Unsaved transcript cleanup ran on shutdown. Saved probe transcripts were removed afterward by their exact plugin-recorded paths.

## Context-budget evidence

The bridge combines runtime-reported occupancy with a UTF-8 byte upper bound, the complete system prompt, a 16,384-token runtime allowance, and an 8,192-token output reserve. It compacts before a predicted turn reaches 72 percent of the configured local budget and refuses a request that still cannot fit. The refusal boundary passed a deterministic check before SDK dispatch. Ordinary authenticated asks and edits completed under the 100,000-token setting.

Claude Code reported a one-million-token physical window and does not expose a native hard ceiling for every requested plugin preset. The plugin therefore labels its policy as a conservative local bound rather than claiming a runtime-native hard cap.

## Remaining limitations

- The official `claude auth login` terminal path is implemented but was not driven because the runtime already had supported first-party authentication.
- The one-hour and five-minute expiry branches were not tested by waiting through real wall-clock TTLs.
- Cancellation and stale-result rejection passed deterministic editor checks, but cancellation was not timed against a live partial model stream.
- Large near-100,000-token paid prompts were not sent. The ordinary request path, conservative refusal boundary, runtime occupancy reporting, and real compaction path were exercised separately.
- Neovim interaction was exercised headlessly. Prompt mappings, focus state, streamed floats, visual replacement, remembered follow-up, and undo were observed through Neovim APIs rather than a human terminal session.

## Implementation choices

Lua owns buffers, extmarks, mappings, floats, undo, context diffs, and presentation normalization. Python owns SDK clients, provisioning, framed transport, session retention, runtime discovery, compaction, and budget admission.

The bridge uses the SDK's normal transcript store so `save` can retain exact earlier turns without replay. Its manifest records only conversations created by this plugin and their exact transcript paths. Cleanup validates that a path is an exact JSONL file below Claude Code's project store before deleting it.

The largest maintenance cost is the target implementation. Blockwise selection cannot be reduced to byte ranges because a boundary may split a tab's display cells. The code expands only the covered tab cells, keeps unselected cells outside remembered follow-up extmarks, and rejects multiline block output.

## Source line counts

The count excludes specification and policy documents, generated files, virtual environments, caches, and external dependencies.

| Area | Lines |
| --- | ---: |
| Lua implementation | 1,453 |
| Python bridge | 651 |
| Static system prompt | 44 |
| Tests | 142 |
| README and changelog | 165 |
| Total counted | 2,455 |

Reproduce from the candidate root:

```sh
wc -l lua/nvim-claude/*.lua python/nvim_claude_bridge.py \
  resources/system-prompt.txt tests/headless.lua tests/test_bridge.py \
  README.md CHANGELOG.md
```
