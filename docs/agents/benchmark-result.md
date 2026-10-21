# Astra 6 medium in NeoPi

## Outcome

**Blocked, not a completed benchmark candidate.** The branch is installable through lazy.nvim and contains the Lua/Python implementation. It does not satisfy the required ordinary editing under a verified hard 100k prompt ceiling. It must not be described as meeting all acceptance criteria or ready for integration under this specification.

The final implementation refuses every explicit local ceiling before any model request. The default remains 100,000; it is not silently raised. Explicit model-default operation is available, but removing the ceiling does not satisfy the missing requirement.

## Identity

- Model: `openai-codex/gpt-6-astra`
- Reasoning: medium, selected by the owner
- Harness: NeoPi `npi/18.4.4`
- Started: 2026-10-21T14:56:38Z
- Baseline: `4c85985bf31be8a0ca03fe0cdc345708479d4f4c`
- Pinned nightly seed: `c1cf1e11bb0e9768c4d62a5cfca1a39fc49789e3`
- Candidate: `experimental/benchmark-astra-6-medium-neopi-20261021T140023Z`
- Run issue: #7, referencing preparation issue #5
- Implementation helpers: none
- No sibling worktrees or sessions were inspected. No `ctl`, `ask`, tmux, systemd scope, or polite-run invocation was used.

## Resolved versions

| Component | Observed version |
| --- | --- |
| Neovim | 0.12.4 |
| Python | 3.14.6 |
| claude-agent-sdk | 0.2.170 |
| Bundled Claude Code | 2.1.306 |
| lazy.nvim smoke runner | 85c7ff3711b730b4030d03144f6db6375044ae82 |

The SDK was installed from the latest released wheel into a private virtual environment. A separate clean installation later provisioned its own environment through the plugin. No system Python packages or user editor configuration were changed.

## Hard-ceiling investigation

The SDK's `get_context_usage()` returned current-context categories and token estimates. With the runtime's 100k auto-compaction window, it reported `maxTokens = 100000`; that is a compaction/context display constraint, not a verified dispatch gate.

The initial implementation checked current token counts plus new UTF-8 input bytes and a 16,384-token runtime allowance. Small Haiku requests passed through this path. Those successful requests do **not** prove a hard ceiling, so this path was not retained as capped-request enforcement.

[Anthropic's token-counting documentation](https://platform.claude.com/docs/en/build-with-claude/token-counting) explicitly calls the count an estimate and permits differences in actual message input. SDK options and runtime CLI controls inspected here did not expose the complete next provider request or a hard input-token limit. The runtime's `CLAUDE_CODE_MAX_CONTEXT_TOKENS` and auto-compaction controls describe context-window behavior; they do not establish the requested guarantee. A Unix-socket interception route also changes authentication behavior, so it was not introduced as an undocumented credential-forwarding workaround.

I did not establish a defensible hard bound for the complete next request. `SPEC.md` requires unsupported budgets to be reported before dispatch in that situation. The final bridge follows that rule. This is a failed acceptance criterion, not a claim that the requested product is complete, and not proof that no other implementation could establish a bound.

## Executed verification

All model probes used `claude-haiku-5-5`, requested thinking disabled, and configured the 100k window with conservative preflight. They ran before the estimate-based capped path was replaced with an unsupported-budget error. No uncapped model requests were used to claim the missing hard-cap criterion.

| Exercise | Observed result |
| --- | --- |
| Runtime discovery | Announced models, resolved IDs, supported effort levels, account type, and CLI version |
| No-tools isolation | Empty model tool/MCP announcements; context contained no memory files, MCP tools/instructions, or agents |
| Real replacement | `The ... brown fox.` returned exactly target `t1` with `quick` |
| Saved continuation | Same logical/SDK session retained after bridge reconnection |
| Prompt override | Reconnected with `snapshot=false`; the next answer obeyed the new `AMBER` system instruction |
| Manual compaction | `/compact` completed and emitted `compact_boundary` |
| Exact saved transcript | SDK readback after bridge exit found the saved session by its UUID and private working directory; cleanup deleted that exact session |
| State transitions | Save, clear preserving a saved checkpoint, new, sticky on/off, list, and exact resume passed |
| Ownership lease | A second store could not acquire a live conversation; cleanup preserved the live owner's manifest |
| Parsing and output validation | Native `[1m]`, explicit limits, retained raw IDs, invalid/duplicate/missing targets, block newlines, and intentional deletion checked |
| Context encoding | General ask omitted document context; snapshot, smaller unified diff, and unchanged revision paths checked |
| Punctuation | Only mapped characters changed; accents and zero-width joiners were preserved |
| Neovim mappings | Commands, default keys, explicit overrides, disabled keys, repeated setup, and existing owner mapping preservation checked |
| Neovim targets | UTF-8, reversed characterwise, linewise, blockwise, partial-tab cells, insertion, stale-content rejection, and deleted-buffer rejection checked |
| Movement and undo | Insertion at the selection boundary and unrelated row insertion moved the target; replacement stayed exact; one undo reversed all block rows |
| Prompt interaction | Buffer-local Ctrl-S and Normal Enter submission bindings, Insert Enter preservation, Escape dismissal, and origin focus restoration checked |
| Published installation | lazy.nvim cloned the GitHub repository at the actual candidate branch, without a local `dir` entry |
| Fresh-process first use | A new Neovim process loaded setup, provisioned its own venv asynchronously, received the unsupported-cap error, and left source text unchanged |
| Bridge shutdown | EOF cleanup completed and the observed bridge job exited |
| Official login command | Bundled `claude auth login --help` confirmed subscription login as default; no browser login was started |

Throwaway scripts were `smoke.py`, `contracts-smoke.py`, `state-smoke.py`, `editor-smoke.lua`, `selection-smoke.lua`, `movement-smoke.lua`, and `installed-smoke.lua`, under this run's private NVMe scratch directory. They exercised the real SDK, storage, and Neovim APIs. No permanent mock backend or test dependency was added.

## Unverified or unmet

- Ordinary editing under a verified hard 100k ceiling: **unmet**. Explicit ceilings fail closed.
- Hard-ceiling boundary behavior with large fresh input, accumulated history, and automatic compaction: **unmet**. Refusal before dispatch is verified; it is not a substitute for successful bounded editing.
- Automatic compaction near a physical context window, elapsed-time cache expiry, and interruption midway through a real model stream were not exercised end to end.
- Saved-session SDK readback and same-process reconnection were exercised; a fresh Neovim process issuing another model turn from a saved session was not separately exercised.
- The interactive OAuth browser flow was not exercised because supported local authentication already worked.
- Neovim verification was headless against actual buffers, windows, mappings, and undo. Attached-TUI visual layout and real keyboard prefix timing were not visually reviewed.
- Neovim 0.11 and Python 3.10 minimum-version installations were not separately run.
- Cumulative usage carries per-connection SDK deltas across reconnects, but this final accounting change was not separately model-probed.

## Implementation choices

Lua owns target positions, editor state, floats, mapping ownership, and atomic edits. Python owns serialized SDK turns and session manifests. The RPC reader can interrupt the SDK while the serial owner keeps client connection/disconnection in one task. Request epochs prevent results from applying after cancellation or a conversation switch.

The latest SDK supplies exact session deletion and discovery APIs, so cleanup uses UUID plus a plugin-owned working directory rather than guessing transcript filenames. Advisory locks protect saved sessions from concurrent owners. Provisioning publishes a new environment only after pip succeeds, under a separate installer lock.

Blockwise capture uses Neovim's own `getregion`/`getregionpos` geometry. Partial tabs become selected spaces plus preserved outside cells. Extmark gravity distinguishes insertion points from nonempty selections, allowing outside boundary edits to move a remembered target without absorbing new text.

## Source size

Count command: `wc -l lua/nvim-claude/*.lua python/*.py python/system.txt`.

| Source | Lines |
| --- | ---: |
| Lua | 637 |
| Python | 658 |
| Static system prompt | 44 |
| Total | 1339 |

Counts include comments and blank lines. They exclude documentation, throwaway smoke scripts, generated files, installed dependencies, and runtime data. The size is not evidence of completeness; the hard-ceiling failure remains decisive.
