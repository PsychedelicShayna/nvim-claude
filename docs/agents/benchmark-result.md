# Sol 6.1 high / NeoPi candidate

## Identity and baseline

- Provider/model: `openai-codex/gpt-6.1-sol`.
- Candidate effort label: `high`, from the operator's explicit `sol-6-1-high` version. The model and effort were not switched. No separate normalized effort value was exposed to this run by a metadata tool.
- Harness: NeoPi. A harness build/version identifier was not exposed.
- Same-model helpers: `EditorTargets` and `EditorInteraction`, both explicitly dispatched as `openai-codex/gpt-6.1-sol:high`. They implemented separate Lua modules; the parent owned integration, provisioning, RPC, the SDK bridge, documentation and all executed verification. No other model implemented or reviewed this candidate.
- Implementation began at approximately 2026-10-21 16:20 UTC.
- Baseline: `4c85985bf31be8a0ca03fe0cdc345708479d4f4c`.
- Pinned nightly seed: `c1cf1e11bb0e9768c4d62a5cfca1a39fc49789e3`.
- Branch: `experimental/benchmark-sol-6-1-high-neopi-20261021T161659Z`.
- Run issue: #19; benchmark preparation: #5.

No sibling worktree, source, design or session was inspected. No `ctl` or `ask` call was used. The actual TUI ran on a separately named private tmux server, never in the operator's tmux session. Temporary profiles/environments were placed on the secondary NVMe under this candidate's own directory.

## Runtime observed

| Component | Resolved version |
| --- | --- |
| Neovim | 0.12.4, LuaJIT |
| Python | 3.14.6 |
| claude-agent-sdk | 0.2.170, latest released package resolved during setup |
| Bundled Claude Code | 2.1.306 |
| Model used for inference | claude-haiku-5-5 |
| Reasoning | disabled; observed thinking token count zero |
| Effort | low |
| Local prompt ceiling | 100,000 tokens, with a separate 50,000 refusal probe |

The bundled executable reused the runtime's supported existing subscription authentication. No credentials were copied, no API-key fallback was used, and no login was needed to run the probes. The official `auth login` terminal path is implemented but a fresh OAuth login was not performed, to avoid changing the operator's active account.

Runtime metadata announced model selectors, resolved model IDs and supported effort levels. The UI uses those announcements rather than a static catalogue. The effective initialization reported an empty model tool set and no MCP servers; context usage reported no loaded memory files, MCP tools or agents. The runtime still announces built-in slash-command/plugin metadata, which is not treated as proof those commands are model-callable. The model-accessible tools were empty on actual turns.

## Executed verification

Checks used small direct Python/Neovim processes, not builds, full test suites, systemd scopes or polite-run. One model bridge was exercised at a time. The following temporary smoke scripts were executed from the run-specific NVMe directory and removed after delivery.

| Exercise | Observed result |
| --- | --- |
| `nvim --headless -u NONE -l editor_smoke.lua` | Commands loaded; existing mappings preserved; explicit overrides and `keys=false` worked across repeated setup. UTF-8 and reversed selections, moving targets, block replacements, remembered spans, exact insertion and one-step undo passed. Prompt/answer float lifecycle preserved origin focus. |
| `nvim --headless -u NONE -l target_edges.lua` | Native virtual-edit partial-tab selection preserved outside cells. Block edits undid together. Interior edits followed by undo invalidated the old target. Multiline block output was rejected atomically, exclusive selection was respected, and a deleted source was not edited. The first virtual-offset probe omitted `virtualedit`; rerunning with the native option enabled exercised the intended selection instead of assuming virtual offsets apply when disabled. |
| `python bridge_smoke.py` | Real Haiku replacement returned only the target edit; a follow-up remembered it. `/compact` emitted a real compact boundary and retained the word afterward. Changing the system prompt affected the next request. Save/new/list/exact resume worked. A 50k mandatory-input conflict was refused. |
| `python budget_smoke.py` | Accepted 48,000 bytes of fresh padding with an accounted history bound of 50,167 and runtime occupancy of 25,395 tokens. Accumulated history triggered actual native compaction before the next ask. A 400k-byte document used explicitly incomplete bounded fragments around the intact target. A 120k-byte mandatory general instruction was refused before model dispatch. Sticky on/clear/off preserved saved checkpoints. |
| `python cancel_smoke.py` | Interrupted an active SDK request after its requesting event. The cancelled turn completed as an error before the cancel acknowledgement, with no replacement result. The immediately following turn succeeded. An initial throwaway assertion expected no period despite asking with a final period; the observed reply was valid, and that incidental wording assertion was removed. |
| Resumed usage check in `bridge_smoke.py` | Cumulative counters were compared with the SDK's persisted per-model totals across system-prompt reconnect and saved-session resume, including compaction. This exposed a double-counting assumption about resumed counters, which was corrected by keeping the previous cumulative snapshot with the conversation. |
| Python contract boundary calls | Manual native variants, explicit local limits, colon-bearing IDs and supported-effort retention passed. Malformed, duplicate and multiline-block edit envelopes were rejected; an intentional empty replacement was accepted. |
| Clean lazy.nvim install | Installed `PsychedelicShayna/nvim-claude` by this published branch, with `main="nvim-claude"` and `opts={}`. No local `dir` entry or private configuration was used. |
| Fresh Neovim after installation | Loaded source from the plugin-manager clone, registered Normal/Visual defaults with Insert generation disabled, provisioned its own SDK environment asynchronously, inserted `XYZ` at the captured boundary, preserved a concurrent unrelated edit, and undid only the generated edit. A timer fired 873 times while provisioning/inference ran. General ask streamed `READY` without changing source. |
| Final published-code restart | lazy.nvim updated the installed clone to code commit `4ef8d8b`. A fresh Neovim reran the installed generation/ask/undo smoke successfully, reused the provisioned environment, and recorded 307 responsiveness timer ticks. |
| Actual Neovim TUI | Captured the cursor-local prompt surface, typed a multiline instruction with Insert Enter, submitted with Ctrl-S, and observed `TUI_READY` in the completed answer float. `q` closed the answer; Insert Escape followed by Normal Escape dismissed an unsubmitted draft and restored the source window. |

The README records the supported setup/key API, commands, storage, billing boundary, budget policy and runtime limitation. The implementation's prompt is a static resource, and source output is never trimmed or treated as a patch.

## Budget evidence and limits

The implementation uses UTF-8 bytes as a conservative token upper bound for supplied prompt/history content, plus a 16,384-token runtime allowance. It validates effective context isolation and reported occupancy, reserves 4,096 output tokens, checks native compaction requests too, and refuses input that cannot fit an empty conversation. Context compaction is triggered early by the host, not mistaken for a hard runtime wall.

The guard was exercised for ordinary editing, large fresh input, accumulated history, manual/automatic compaction, long-line excerpts, and mandatory-input refusal on CLI 2.1.306. This is a conservative local guard with an explicitly validated runtime allowance, not a provider-side arbitrary hard-limit API or exact tokenization of unseen future runtime additions. It can reject input a tokenizer would fit. Unvalidated runtime versions fail closed for inference instead of advertising a false cap. Latest-on-first-setup provisioning is still honored.

The SDK reports a 1,000,000-token model capacity separately from the effective 100,000-token auto-compaction window. `info` exposes those separately, along with current occupancy, local bounds, cumulative runtime token counters and estimated cache lifetime. Interrupted/error turns may not supply complete usage counters.

Not every preset, supported model, display geometry or platform was exercised. The chosen minimum is Neovim 0.12 and Python 3.10; only Linux with the versions above was actually run. Native Windows is unsupported. Cache TTL and inactivity expiry are estimates rather than proof of provider cache warmth. No hour-long sleep was used to test real-time expiry. Wide-character and short-line behavior relies on native getregion/getregionpos semantics; the focused virtual-cell smoke explicitly exercised tabs, while UTF-8 characterwise and short-row block targets were also run.

Native compaction is observably lossy. Earlier probes retained the exact inserted word; one later probe returned a valid summary but omitted it, and the follow-up correctly reported that the detail was unavailable. The plugin does not promise verbatim recall after compaction and always invalidates document baselines at its confirmed boundary.

## Design and maintainability

Lua owns editor state, mapping ownership, extmarks and undo; Python owns a single serialized SDK client actor. SDK connection/disconnection stays on the actor task to respect its async lifetime. Cancellation is received independently but acknowledged only once the turn drains. Request IDs and editor epochs reject stale output.

Provisioning serializes installation with a file lock and publishes complete SDK generations atomically. Conversation manifests and per-conversation locks distinguish saved sessions, active editors and abandoned unsaved records. Cleanup resolves only the exact UUIDs the plugin generated; it does not sweep unrelated Claude sessions. Saved history resumes the runtime transcript rather than replaying a model-generated reconstruction.

The main tradeoff is conservative budgeting and version validation instead of a guessed tokenizer or a soft threshold advertised as a hard wall. Another is keeping a small custom framed transport rather than adding an LSP or WebSocket dependency. No permanent test framework or generated dependencies are shipped; the actual runtime and editor were exercised through disposable smoke scripts.

## Reproducible source counts

Command, from the candidate checkout:

```sh
wc -l lua/nvim-claude/init.lua lua/nvim-claude/rpc.lua \
  lua/nvim-claude/targets.lua lua/nvim-claude/ui.lua \
  python/bridge.py python/contracts.py python/provision.py python/storage.py \
  resources/system.txt
```

| Source | Lines |
| --- | ---: |
| Lua editor client, targets, UI and transport | 1,453 |
| Python bridge, contracts, provisioning and storage | 727 |
| Static system prompt | 44 |
| Total | 2,224 |

Counts include blank lines/comments and the static prompt, and exclude docs, tests, dependency files, generated bytecode, virtual environments and temporary verification scripts. There are no shipped permanent tests or generated sources. Fewer lines alone do not establish maintainability.

## Delivery

The remote candidate branch is the installable artifact. The draft comparison PR targets `benchmark`, remains unmerged and awaits owner selection. The exact delivered commit is recorded in that PR and the final reply, avoiding a self-referential commit hash in this file. Local candidate/test resources are removed only after all intended commits are pushed and the remote ref is verified. The launcher and remote candidate branch are retained.
