# Astra 6 low candidate

## Outcome

An installable candidate is published, but this run does **not** satisfy the full benchmark contract. Strict 100k prompt enforcement is unresolved. Default strict mode refuses model dispatch rather than pretending an estimate is a hard cap. Explicit conservative mode has working, exercised editing and conversation behavior, but it is not a substitute for SPEC.md acceptance scenario 10. The candidate must not be promoted as a passing implementation.

## Identity

- Model: `openai-codex/gpt-6-astra`
- Reasoning: low, selected by the owner
- Harness: NeoPi; exact harness version was not exposed in session metadata
- Start: 2026-10-21T14:56:47Z
- Last installation verification: 2026-10-21T15:39:24Z
- Baseline: `4c85985bf31be8a0ca03fe0cdc345708479d4f4c`
- Pinned nightly seed: `c1cf1e11bb0e9768c4d62a5cfca1a39fc49789e3`
- Branch: `experimental/benchmark-astra-6-low-neopi-20261021-a7d3`
- Run issue: #10, preparation reference #5
- No helper models, other candidate worktrees, `ctl`, shared tmux sessions, systemd scopes or polite-run were used. No tmux session was needed.

The final code commit exercised through the published lazy.nvim installation was `c8bac86e8119f403bea66b90ed808cf88c6df095`. Subsequent changes record evidence only. The comparison PR records the delivered commit without making this file self-referential.

## Runtime versions

| Component | Observed version |
| --- | --- |
| Neovim | 0.12.4, LuaJIT 2.1.1784580905 |
| Python provisioned by the plugin | 3.14.6 |
| Latest SDK resolved during this run | 0.2.170 |
| SDK-bundled Claude Code | 2.1.306 |
| Test model | claude-haiku-5-5 |
| Test reasoning | SDK `thinking={"type":"disabled"}`, effort low; observed usage reported zero thinking tokens |

The runtime announced 13 model entries. It reported Haiku 5.5 as the resolved `haiku` model, with low/medium/high/xhigh/max effort metadata. It reported `supportsThinkingOff=false` for that entry even though the exercised disabled-thinking requests returned zero thinking tokens. The implementation passes the requested disabled thinking configuration; it does not claim the metadata guarantees that every future response is reasoning-free.

Existing Claude Max authentication worked without copying credentials or changing billing mode. No API-key variables were present in the probe environment. The official bundled `auth login` command is wired to a Neovim terminal, but no new login was completed because the existing account was authenticated.

## Executed verification

Checks used disposable scripts under this run's own `/mnt/alias/m2/tmp/experimental/benchmark-astra-6-low-neopi-20261021-a7d3` directory. They were not installed as plugin dependencies or permanent tests. SDK/model probes ran serially. No build, full test suite or parallel model fan-out ran.

| Check | Observed result |
| --- | --- |
| SDK initialization and real Haiku response | Runtime model metadata available; empty tools and MCP lists; expected text response |
| No-skills content configuration | `tools=[]`, empty strict MCP/settings sources, no agents, and `--disable-slash-commands` yielded no advertised skills on content turns |
| Manual `/compact` | Real `compact_boundary` event and successful result; remembered word survived summary |
| Prompt replacement | Reconnected exact SDK session with custom `snapshot=False`; next response obeyed changed system prompt |
| `editor_smoke.lua` in actual headless Neovim | UTF-8 replacement, literal spaces, one undo, unrelated edits moving targets, inside-target invalidation, block edits and captured insertion after focus change passed |
| `block_smoke.lua` | Partial tabs, wide characters and short virtual rows preserved unselected cells; block edits undid together; reversed exclusive UTF-8 and linewise selections passed |
| Pure contract checks | Manual model expressions, malformed/duplicate/missing edit targets, multiline block rejection, intentional deletion and punctuation-only Unicode normalization passed |
| Framed `bridge_smoke.py` | Strict budget refused before a model turn; conservative replacement produced exactly `quick`; streaming did not duplicate final text; save/compact/new/resume and prompt replacement passed |
| `edge_smoke.py` | 100,000-byte mandatory input refused without partial output; accumulated conservative history triggered proactive compaction; general asks had no document attachment; cancellation after streaming returned a canceled result |
| `retention_smoke.py` | A new bridge resumed saved SDK history; another owner could not acquire the same saved conversation; shutdown deleted the exact unsaved SDK transcript and manifest |
| Embedded `ui_smoke.py` | Real key input exercised multiline Enter, Normal Enter, Ctrl-S, two-step Escape, preserved/overridden/disabled mappings, ordinary typing during a real replacement, isolated undo, streamed ask, result hiding and focus restoration |
| GitHub + lazy.nvim cold installation | Installed by repository name and candidate branch, not `dir`; restarted into a clean XDG environment; setup exposed commands before a venv existed; first use provisioned a fresh SDK environment and completed a real replacement and ask while ordinary typing remained possible |
| `keys=false` after normal lazy setup | Removed plugin Normal and Visual replacement mappings; `:NvClaude` remained registered |
| Signed commits | Each commit was verified with `git verify-commit HEAD` before pushing |

The cold-install fixture used `main = "nvim-claude", opts = {}` to verify registration. It then explicitly selected conservative mode for model-backed checks. It asserted that the loaded Lua module belonged to lazy.nvim's GitHub checkout and that no venv existed before first use. The final cold first-use run completed in 17.82 seconds. This is one observed run, not a performance guarantee.

The saved-history, cancellation and ordinary UI probes used the real SDK. No fake SDK responses were used as evidence of model-backed behavior.

## Defects found during the run

1. The first float-resize change omitted Neovim's required `relative` field. The embedded UI stalled on the resulting error. A direct API probe reproduced `Required: 'relative' when reconfiguring floating window`; the corrected UI probe passed.
2. The bridge replied with an error before client teardown completed. An immediate next request was incorrectly rejected as busy. Responses now follow teardown and clearing of active state.
3. Disabling slash commands also disabled `/compact`. The first bridge compaction probe correctly rejected the missing boundary. Compaction now reconnects only for the built-in command, with tools still disabled, then restores the ordinary no-skills configuration.
4. The first cold-install UI run stalled on long pip notifications, despite warm-environment checks passing. A focused embedded-Neovim probe reproduced `mode='r', blocking=true` for long notification output. First-use output now emits only short progress messages; explicit update logs go to a float. The cold installed-branch probe then passed.
5. Cancellation accounting and queued dispatch were tightened after the first streaming probe. Input and streamed bytes are counted even on interrupted turns; queued content requests can be canceled before model dispatch.

Two stalled UI probe jobs were terminated by their deadlines, and one was canceled after its failure was identified. They are not reported as passing checks. The later passing runs exercised the fixes.

## Unresolved requirement and verification limits

The official environment-variable reference documents auto-compaction windows and percentage triggers, not a hard bound on the next prompt. SDK `get_context_usage()` describes current context. `TaskBudget` describes an API-side task/output pacing budget, not a next-request input ceiling. The actual runtime also adds context attachments beyond the supplied system prompt and user JSON.

This run did not establish an authoritative upper bound for those additions. The byte-based conservative allowance is deliberately labeled an estimate. Strict finite-budget turns and strict compaction refuse before dispatch. This preserves the refusal boundary but leaves ordinary strict-mode editing unavailable, so the specification is not fully implemented. A runtime-supported authoritative preflight count or enforced prompt-size control is the missing prerequisite. No successful conservative-mode probe changes that conclusion.

Other limits:

- Native Windows is unsupported because provisioning and ownership use POSIX `flock`.
- Only Neovim 0.12.4 and Python 3.14.6 were exercised. Python 3.10+ is the code/SDK requirement, not a claim that every such version was tested.
- Subscription eligibility for distribution remains subject to Anthropic's terms. A new interactive login was not exercised.
- Exhaustive model variants and every picker effort were not queried. Model metadata is runtime-supplied; unknown manual effort support is not certified.
- No automated crash-at-every-storage-boundary test or multi-instance cold-install race test ran. Ownership locking was exercised with a live saved conversation; clean transcript deletion was checked through the SDK.
- The prompt-ceiling criterion blocks an unqualified completion claim or recommendation to merge this candidate.

## Implementation choices

Lua modules separate public commands/mappings, target tracking, floats and framed RPC. Python separates environment provisioning, pure contracts, owned session storage and the SDK worker. There is one lazy bridge per editor and one serialized SDK conversation. Content input is JSON; static model instructions live in `resources/system.txt`. Source edits remain entirely in Lua.

The SDK owns the exact runtime transcript. The plugin manifest records owned IDs and completed raw turns. Locks prevent deletion or resumption by a second live bridge. Model and prompt changes resume the SDK session rather than replaying assistant messages. Context baselines advance only after a successful turn and are invalidated on uncertain delivery or compaction.

The implementation is small enough to inspect directly, but the unresolved budget contract matters more than its line count. No comparison with another candidate's implementation was made.

## Source counts

Reproduce with:

```sh
wc -l lua/nvim-claude/*.lua python/*.py resources/system.txt
```

| Source | Lines |
| --- | ---: |
| Lua | 700 |
| Python | 692 |
| Static system prompt | 44 |
| Total | 1,436 |

Counts include blank lines and comments. They exclude product/policy documents, temporary smoke scripts, dependencies, bytecode and generated files. No vendored SDK or virtual environment is committed.
