# Astra NeoPi candidate result

The candidate is implemented and installable from its published branch. It remains unmerged, awaiting owner comparison. No other candidate's code or worktree was inspected. No subagents, control tool, ask tool, tmux session, systemd scope, or polite-run command was used.

## Identity and baseline

- Model: `openai-codex/gpt-6-astra`.
- Effort: xhigh, as identified by the owner for this original run. The session's supplied machine metadata did not independently expose an effort field.
- Harness: NeoPi, installed CLI reports `npi/18.4.4`.
- Baseline: `4c85985bf31be8a0ca03fe0cdc345708479d4f4c`.
- Pinned nightly seed: `c1cf1e11bb0e9768c4d62a5cfca1a39fc49789e3`.
- Candidate branch: `experimental/benchmark-astra-6-neopi-20261021T135334822264899Z`.
- Worktree created: 2026-10-21T13:53:34Z. Implementation started after the owner's subsequent BEGIN message on the same date.
- Run issue: [#8](https://github.com/PsychedelicShayna/nvim-claude/issues/8), following preparation issue #5.
- Implementation helpers: none.

The owner's six-run reasoning-level tournament supersedes the older four-run description in the launcher documents. This run preserved its original branch identity rather than starting a second candidate.

## Resolved environment

| Component | Observed version |
| --- | --- |
| Neovim | 0.12.4 |
| Python | 3.14.6 |
| Claude Agent SDK | 0.2.170 |
| Bundled Claude Code | 2.1.306 |
| Model used for inference | `claude-haiku-5-5` |
| Model effort / reasoning | low / disabled |
| Requested local prompt ceiling | 100,000 tokens |

The installed runtime announced model selectors and supported effort levels through `get_server_info()`. It announced no agents, MCP servers, memory files, or MCP tools under the plugin's isolated configuration. Initialization events and the outgoing request gate additionally checked the no-tools contract. The runtime discovered an existing claude.ai Max login. No refresh tokens were copied and no API-key fallback was used.

## Observed verification

All model probes ran sequentially, with SDK clients closed after use. Disposable configs, venvs, scripts, and installations lived only under this candidate's directory on the secondary NVMe.

| Check | Observed result |
| --- | --- |
| Actual lazy.nvim repository installation | Installed `PsychedelicShayna/nvim-claude` with the candidate branch, `main = "nvim-claude"`, and `opts = {}` in isolated XDG directories. No local `dir` entry or private config was used. Restarted Neovim before interactive verification. |
| Installed code identity | Final code check used `664a64d2f39d016ceaf02f5b02298b8b27dbdda9`; later delivery changes only this evidence document. The loaded module path was inside lazy.nvim's GitHub clone, not this worktree. |
| First-use provisioning | Opening and dismissing a prompt did not create a venv. First submitted generation asynchronously installed the latest SDK, started the bridge, and returned a real edit. Source editing remained possible during installation. |
| Prompt keys and geometry | Attached a real Neovim UI at 100×30 through its embedded API. Verified initial Insert mode, multiline Enter, Ctrl-S submission, Normal Enter submission, two-stage Escape, bounded float geometry, and origin-window restoration. |
| Generation and undo | Inserted `hello ` before the captured `X` while an unrelated second line was edited. The result was `hello X`; one undo removed only the model insertion and preserved the user's second-line edit. |
| Character selections | Headless Neovim exercised UTF-8 emoji/accented selections, reversed endpoints, exclusive selection, linewise replacement, and replacement follow-up. |
| Block selections | Exercised row-specific replacements, one-step undo for the complete block, partially selected tabs preserving outside cells, native wide-character geometry, and virtual columns beyond a short line. |
| Target safety | Outside-target changes moved extmarks safely. Inside-target changes refused replacement. Undo invalidated the remembered result. A changed current buffer did not redirect a captured insertion. |
| Busy drafts and independent ownership | With the first replacement running, opened and submitted a second prompt on another target. Its draft remained open. The first edit applied without stealing focus or destroying the second target; resubmission then edited the second target. |
| Replacement and ask follow-ups | Actual default mappings replaced `...` with `second`, then refined that remembered result to `SECOND`. Selected ask and its Normal mapped follow-up both answered from the same selected target without changing source text. |
| Ask and hidden result | Ask streamed into its float, left the source unchanged, and reopened through `result`. Closing with `q` restored the origin. |
| Cancellation | Canceled an installed-plugin generation; the source remained unchanged. The epoch guard rejects late edits independently of SDK interrupt timing. |
| Mapping configuration | Verified default command registration, preservation of an existing user mapping, explicit overrides, individual disabling, all-key disabling, and repeated setup. |
| Real edit envelope | Haiku returned the requested target-addressed JSON replacement for `...` → `quick`. The ordinary request's complete-wire bound was 21,826 under the requested 100k ceiling. |
| Manual compaction | The runtime accepted `/compact` and emitted `compact_boundary`; the plugin invalidated document baselines. |
| Large fresh input and automatic compaction | A roughly 60 KB instruction produced `SEED_OK`; the complete-wire bound was 81,687 against an effective 95,904 limit after output reservation. The next turn triggered real early compaction and retained the requested code `cedar-347`. |
| Budget refusal | A local wire request bounded at 100,454 was refused before forwarding against a 100,000 limit. A 100,000-character mandatory fresh instruction was refused before model dispatch. The gate also rejected tool-bearing requests and browser Origin headers. |
| Persistence and expiry | Saved an actual SDK session, cleared working context without deleting it, closed the bridge, created a new bridge, resumed the exact saved session, and recovered `cedar-347`. Forced an expired unsaved timestamp and observed a new conversation. Exercised sticky on/off transitions. |
| Ownership cleanup | Separate Store instances could not claim or sweep a live lease. Saved records survived reopening. Abandoned unsaved records were removed. The installed plugin's session directory was empty after orderly editor exits. |
| System prompt editing | The runtime applied `snapshot = false` overrides to the next turn while preserving history. In the installed UI, saving the scratch prompt was acknowledged and the next ask returned exactly `OVERRIDE_OK`. |
| Context and output policy | Pure checks exercised explicit unchanged markers, append-only unified diffs, model-expression examples and colon handling, punctuation preservation, intentional deletion, and malformed/duplicate/missing/multiline-block response refusal. |

Commands included standalone `nvim --headless -u NONE -i NONE -l ...` target probes, a Python pynvim driver against a fresh embedded Neovim with an attached UI, isolated `Lazy! sync` / `Lazy! update nvim-claude`, and sequential Python SDK probes. Throwaway drivers were removed after verification. No full test suite or build was needed for this Lua/Python plugin.

## Failures found during the run

- The first UTF-8 smoke exposed that `getregionpos()` reports an inclusive final byte, not the start byte of the last character. Advancing that value consumed an unselected character. The range conversion was corrected and the smoke passed.
- The first attached-UI driver blocked on an actual prompt resize error. Updating a float's row requires `relative`; the corrected resize supplies the complete position tuple. The installed keyboard-driven check then passed.
- The disposable lazy.nvim bootstrap initially used a single-branch clone of a tag, leaving its own default remote branch unset. This caused lazy.nvim's lock writer to assert. Repairing that disposable manager's remote metadata fixed installation; the candidate itself did not need a workaround.
- The combined follow-up driver did not wait for asynchronous prompt-save acknowledgement before closing the prompt-edit buffer. Its earlier concurrent-target and follow-up checks passed. A separate driver waited for the saved buffer state and handled native message prompts; the next-turn override check passed.

## Design and constraints

Lua is split into editor orchestration, target geometry, floats, and transport. Python is split into the RPC actor, runtime, storage, pure request policy, provisioning, and the complete-request gate. The SDK client is connected and disconnected by one sequential actor task, preserving its async task-scope requirements. Interrupt requests can arrive while that actor is streaming.

The hard-admission mechanism is deliberately conservative. The local gate counts the complete serialized request's UTF-8 bytes, including SDK-added system/history content, plus 16,384 tokens for provider framing. It enforces this bound before forwarding any model request, including compaction, to the official first-party HTTPS endpoint. This uses the byte-fallback tokenization bound, not a chars-per-token average or a compaction threshold. The provider-framing reserve is an explicit assumption, not visibility into private server processing. Consequently, useful text may be refused well before its exact token count reaches the chosen limit. Runtime occupancy and cache lifetime remain estimates and are labeled separately.

The gate adds one loopback-only HTTP hop with an unguessable per-process path; the editor RPC remains stdio. Headers and request bodies are never logged or persisted by the gate. This extra component is justified by the SDK's lack of a hard complete-prompt limit, rather than used as a general proxy abstraction.

Supported deployment is POSIX Neovim with Python. Windows is not supported because environment/session ownership uses `fcntl` locks and POSIX venv paths. Linux was exercised; macOS, the minimum declared Neovim/Python versions, explicit paid API billing, and model inference other than Haiku were not exercised. The official login command was inspected and wired, but a fresh interactive OAuth login was not performed because existing supported credentials were available. No claim is made about third-party subscription eligibility.

The request gate intentionally refuses custom providers and opaque/non-text input that cannot be bounded. Manual model IDs remain possible; unsupported effort values are rejected rather than silently advertised. The plugin does not promise forensic erasure of SDK diagnostics or remote provider storage.

## Source size

Reproduced with:

```sh
git ls-files 'lua/*.lua' 'lua/**/*.lua' 'python/*.py' resources/system.txt | xargs wc -l
```

| Source | Lines |
| --- | ---: |
| Lua editor client | 714 |
| Python provisioning and bridge | 776 |
| Static model prompt | 44 |
| Total | 1,534 |

Counts include blank lines and comments. They exclude documentation, dependencies, generated caches, and throwaway verification scripts. No permanent test suite or generated/vendor source was added. The small module boundaries make targeting, transport, and request policy independently inspectable; line count alone is not evidence of correctness or a comparison with other candidates.

## Delivery

All implementation commits are agent-signed and their signatures were verified before pushing. The remote candidate branch is retained. The draft comparison PR targets `benchmark`, not nightly or master, and must not auto-merge. The branch is intended to be mergeable in theory, but actual integration remains the owner's decision. The delivered commit and PR URL are recorded in the final handoff rather than embedded self-referentially in this file.
