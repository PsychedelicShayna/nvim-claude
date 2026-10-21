# Sol 6.1 medium candidate

## Identity and outcome

- Model: `openai-codex/gpt-6.1-sol`, medium reasoning, selected by the owner.
- Harness: NeoPi `18.4.4`.
- Started: 2026-10-21T14:58:15Z. Final runtime verification: 2026-10-21T15:24:12Z.
- Baseline: `4c85985bf31be8a0ca03fe0cdc345708479d4f4c`.
- Pinned nightly seed: `c1cf1e11bb0e9768c4d62a5cfca1a39fc49789e3`.
- Candidate: `experimental/benchmark-sol-6-1-medium-neopi-20261021-7c92a`.
- Run issue: #12, preparation #5.
- Helper: one `openai-codex/gpt-6.1-sol:medium` agent implemented the Lua editor client. The parent implemented the Python bridge, integrated changes and performed verification. No other candidates were inspected. No `ctl`, tmux or higher-effort helpers were used.

The branch is installable through lazy.nvim and has real model-backed editing, streaming, persistence and compaction. **It is not a full SPEC pass.** The required verified hard input ceiling is not available through the inspected SDK/runtime contract. Numeric ceilings, including the default 100k, fail closed before model dispatch. The user can explicitly select model default to run without a local pricing ceiling. This is a reported acceptance gap, not permission to integrate the candidate or a claim that the missing ceiling works.

## Resolved environment

| Component | Observed version |
| --- | --- |
| Neovim | 0.12.4 |
| Python | 3.14.6 |
| Claude Agent SDK | 0.2.170 |
| Bundled Claude Code | 2.1.306 |
| Model used for probes | claude-haiku-5-5 |

The client uses Neovim 0.10+ APIs and Python 3.10+ syntax/runtime support. Those minimum versions were not exercised. Provisioning requires `flock`; the verified platform is Linux. Each model probe used one runtime at a time and small output requests. No model request in the large-context probe exceeded 100k measured input. The runtime was asked to disable thinking. Its catalogue reports `supportsThinkingOff=false` for Haiku 5.5, so effective thinking-off cannot be promised. Observed probe usage included zero thinking tokens, which does not establish a general guarantee.

## Verification performed

Focused throwaway probes ran beneath this run's directory on the secondary NVMe. There was no full suite, build, formatter, systemd scope or permanent mock backend. Probes were removed after recording their results.

| Probe | Observed result |
| --- | --- |
| `nvim --headless -u NONE -l editor.lua` | Characterwise, reverse multibyte and linewise selections; movement after unrelated edits; invalidation after target edits; block replacement as one undo; existing user mapping preservation; overrides/disabling; repeated setup passed. |
| `nvim --headless -u NONE -l boundaries.lua` | Forward/reverse exclusive characterwise ranges, partial tab cells, wide-character endpoints, captured insertion after switching buffers, moving replacement targets and dead-buffer refusal passed. Partial-tab output preserved both unselected sides as spaces. |
| `nvim --headless -u NONE -l keys.lua` | Real feedkeys inserted a multiline prompt with Enter; Escape left Insert without closing; the next Escape closed the prompt and restored origin focus. |
| `nvim --headless -u NONE -l live.lua`, isolated XDG dirs | First-use venv/SDK install stayed asynchronous while a timer ran. Real Haiku changed `...` to `quick`, a remembered-target follow-up changed it to `QUICK`, undo/redo affected only that result, general ask retained history without editing the source, answer close restored focus, and cancellation left the source unchanged. |
| Python `smoke.py` using `Bridge` and the real SDK | Target-addressed JSON edit, partial text events, save, prompt replacement on the very next request, an actual `compact_boundary`, exact SDK resume and raw history reuse passed. A strong replacement prompt produced `quick ZEBRA` while retaining the earlier edit context. |
| Python `budget.py`, before the final fail-closed policy | A large mandatory request was refused before dispatch. A real fresh prompt reported 50,400 input tokens. The subsequent turn automatically compacted and reported 2,488 context tokens. Ephemeral expiry created a fresh logical conversation. This tested conservative planning, not a verified hard billing ceiling. |
| Python `retention.py` | A fresh bridge resumed saved SDK history and remembered `otter`. A second owner could not acquire the session lease. Sticky saved the current session; clear retained its saved checkpoint. Closing an unsaved conversation removed its exact SDK session record. Saved test sessions were explicitly deleted afterward. |
| Clean lazy.nvim installation | `Lazy! sync` cloned the actual GitHub repository at this candidate branch. A fresh Neovim process loaded `main='nvim-claude'` with `opts={}`, registered commands/default maps, exercised overrides and `keys=false`, opened/dismissed a prompt, provisioned a new plugin-owned runtime and discovered five runtime model rows. No local `dir` entry or private config was used. |
| Final published-runtime probe | `Lazy! update nvim-claude` installed code commit `dd8b5fb37cede6276c3daecb6122b2421221060b`. Its own provisioned Python and published bridge refused the default hard cap with an empty transcript. After an explicit model-default choice, replacement, prompt override, real compaction and resume passed. Disconnect was followed by an OS check confirming that the exact runtime PID no longer existed. |

Editor verification was headless against actual Neovim windows, mappings, buffer APIs and input processing. Terminal appearance was not visually inspected. Ctrl-S and Normal Enter submission callbacks were inspected; the live editor probe invoked the registered Ctrl-S callback. Actual feedkeys covered multiline entry and Escape. A full manual keyboard tour was not performed.

## Runtime findings and decisions

- `tools=[]`, strict empty MCP configuration, `setting_sources=[]`, empty agents/skills/plugins, disabled hooks/memory/IDE attachment, safe mode and verbatim composed messages restrict model input. Runtime context reported no memory files, MCP tools or agents. Successful initialization reported empty tools, MCP servers, agents and skills.
- `--disable-slash-commands` also disabled `/compact`. The first compaction probe caught that; removing the blanket switch allowed an actual compaction boundary. The runtime's built-in doctor and plugin-authoring skills then needed explicit disabling. Safe mode and an empty skill list alone did not remove those announced skills. The bridge now checks initialization and refuses unexpected skills/tools instead of trusting configuration intent.
- The latest SDK supports custom system prompts with `snapshot=False`. Reconnecting to the exact saved session applies a new prompt while preserving history. A weak suffix instruction was not followed once; a strong replacement prompt confirmed the next-request transition.
- Python owns a serialized SDK worker so connect/disconnect stay in the same asyncio task. Cancellation uses the SDK interrupt path. Lua request IDs and epochs independently prevent late source edits.
- Lua extmarks locate targets, but content equality and byte-change invalidation determine whether edits remain safe. Block segments keep independent IDs and preserve unselected tab cells. A result is validated before any source modification.
- Buffer context is a snapshot, explicit unchanged revision, or zero-based line-splice diff. Failed delivery/reconnect/compaction invalidates baselines. General questions do not attach the open buffer. Raw SDK history is not normalized.
- SDK transcripts remain in the runtime's supported storage, using credentials in place. Plugin manifests record exact session IDs and cwd values. OS leases prevent another live bridge's records from being swept. Saved sessions are not deleted by new/clear.
- No provider fallback model, automatic API-key billing, warming request, file crawler or listening server was added.

## Remaining limitations

1. Strict input ceilings are blocked by missing runtime enforcement/counting support. `get_context_usage` provides accounting but no authoritative pre-send count of the final provider request. UTF-8 byte planning plus an overhead allowance does not establish a hard wall on runtime-added input. The default numeric cap and numeric presets therefore refuse dispatch. This fails the spec's ordinary-edit-under-verified-100k acceptance criterion. No silent budget increase or conservative estimate is presented as a hard ceiling.
2. The official login terminal command is implemented, and real existing subscription authentication worked. A fresh interactive login was not performed; no credentials were copied and no API-key fallback was used.
3. Haiku's announced thinking-off limitation remains an upstream model/runtime constraint.
4. Older advertised API-compatible Neovim/Python versions, terminal visual styling and every possible virtual-column/combining-character selection were not exhaustively exercised.
5. The final automatic compaction trigger at model-default physical-window scale was not exercised with a near-million-token request. Actual automatic compaction was observed earlier at the conservative 100k planning boundary; manual compaction was reverified on final published code.

## Source size

Reproduce with:

```sh
wc -l lua/nvim-claude/*.lua python/bridge.py resources/system.txt
```

| Shipped file | Lines |
| --- | ---: |
| Lua backend | 115 |
| Lua entry/commands | 278 |
| Lua targets | 175 |
| Lua floats | 60 |
| Python bridge | 555 |
| Static system prompt | 44 |
| Total | 1,227 |

Implementation code is 1,183 lines; the separate prompt is 44. Counts include comments and blank lines, exclude documentation, tests, generated files and dependencies. No permanent tests were added. The module split keeps editor state in Lua and SDK/storage state in Python without an extra transport dependency. Small source size does not compensate for the strict-budget acceptance gap.
