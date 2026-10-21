# Astra 6 high in NeoPi

## Outcome

**Non-passing candidate. The full task is not complete, and this branch is not recommended for integration.** The remote branch is installable and its editor/provisioning paths work, but ordinary model-backed editing under the required 100k ceiling is blocked. No uncapped inference was sent to make the candidate appear complete.

Draft comparison PR: [#21](https://github.com/PsychedelicShayna/nvim-claude/pull/21). Run issue: [#18](https://github.com/PsychedelicShayna/nvim-claude/issues/18). Neither is a request for automatic promotion.

## Identity and baseline

- Model: `openai-codex/gpt-6-astra`
- Effort: high, as selected and named by the owner for this worktree. The later tournament announcement describes xhigh, medium and low; this run retained its existing identity rather than silently changing it.
- Harness: NeoPi. Its version was not exposed in the session metadata.
- Baseline: `4c85985bf31be8a0ca03fe0cdc345708479d4f4c`
- Pinned nightly seed: `c1cf1e11bb0e9768c4d62a5cfca1a39fc49789e3`
- Branch: `experimental/benchmark-astra-6-high-neopi-20261021-7c93b2`
- Start: 2026-10-21T16:20:00Z
- Last verification: 2026-10-21T16:44:21Z
- Implementation helpers: none. No control tool, tmux sessions, other candidates' worktrees or source implementations were used.

The owner asked not to use polite or systemd scopes. The higher-priority workspace instruction explicitly required `polite --mem` for test runs, so focused verification used the existing relay and shared light-test lock. That conflict was disclosed before testing. No build or test fan-out ran. The observed aggregate slice quota was two logical CPUs, with the relay's per-check 4 GiB memory-high and 6 GiB maximum. Initial package inspection ran serially at nice level 15. Scratch and isolated installations used this run's directory on the secondary NVMe.

## Resolved versions

| Component | Observed version |
| --- | --- |
| Neovim | 0.12.4 |
| Python | 3.14.6 |
| claude-agent-sdk | 0.2.170 |
| Bundled Claude Code | 2.1.306 |
| lazy.nvim | `85c7ff3711b730b4030d03144f6db6375044ae82` |

The declared minimums are Neovim 0.11 and Python 3.10 from the APIs used. Those older minimum versions were not separately exercised. POSIX locks make Windows unsupported.

## Exercised behavior

1. `nvim --headless -u NONE -l tests/targets.lua` passed. It exercised literal replacement, follow-ups using the new target, UTF-8 reversed selection, linewise content, extmark movement under unrelated edits, rejection after inside-target edits, captured insertion without duplicated characters, one-step block undo and partial-tab preservation.
2. `python tests/test_contracts.py` passed four focused tests. They cover model-expression/native-selector parsing, a file-free general ask, explicit immutable context baselines and malformed/duplicate/missing/block-multiline edit rejection, including intentional deletion.
3. An isolated subprocess exercise drove the real framed Python bridge. Runtime initialization announced Haiku 5.5 and supported effort levels. It exercised a 100k refusal before inference, save/new/list/resume, system override/reset, sticky mode and EOF shutdown. These were empty-session lifecycle transitions, not proof of populated transcript resumption.
4. A real Neovim process with an attached 100×30 UI exercised repeated setup, preservation of an existing user mapping, defaults, overrides, disabled mappings, multiline Insert-mode input, two-stage Escape dismissal, answer `q`, origin focus and retained hidden answers. The screen showed the cursor-local title and both instruction lines with the source unchanged.
5. The first attached UI exercise exposed a blocking `TextChangedI` error: floating-window reconfiguration needed its `relative` field when updating `row`. The initial exercise timed out, a diagnostic run identified the callback, and the corrected exercise passed. This was a product bug, not a failing test dismissed as infrastructure.
6. A clean configuration installed `PsychedelicShayna/nvim-claude` by remote branch through lazy.nvim, then updated to implementation commit `f1eaf7665f93ec105741d564c047f4eea6a98a87`. No local `dir` entry was used. A fresh Neovim process loaded that installed copy, checked commands/default/overridden/disabled keys, provisioned a new plugin-owned venv, initialized the real SDK, received the capped-request refusal over framed RPC and shut the bridge down cleanly. That first-use exercise took 12.65 seconds including dependency installation.
7. The bundled `claude auth login --help` confirmed the supported official flow and that subscription login is its default. No interactive login, token copying or API-billing fallback occurred.
8. Every published commit was agent-signed and checked with `git verify-commit HEAD` before pushing.

## Runtime evidence and unresolved criteria

The installed SDK has `get_context_usage()` and model metadata, but no typed hard prompt-token limit or authoritative next-request counting API. Its documented `CLAUDE_CODE_AUTO_COMPACT_WINDOW` and percentage override control compaction thresholds, not a guaranteed request-size wall. Inspection of the bundled runtime's environment-variable names found context-window and output-token controls, not a hard input-token limiter. A local byte estimate plus an arbitrary overhead allowance does not prove the requested ceiling.

The bridge therefore refuses every numeric local budget before querying the model. The explicit model-default option removes the local ceiling; it does not preserve 100k protection. This leaves the specification's ordinary Haiku editing and hard-boundary acceptance criteria unmet. The model-default implementation uses conservative estimated capacity checks and runtime `/compact` with a required `compact_boundary`, but no model-backed compaction was exercised.

Initialization reports `supportsThinkingOff=false` for Haiku 5.5. The SDK accepts a disabled-thinking option, but that is not proof the model honors it. The user's requested reasoning-free test configuration could not be established either.

Other unverified model-dependent criteria include successful streamed asks, valid generated edits, exact retention/resumption of populated SDK transcripts, manual and automatic compaction, accumulated-history budgets and next-request system-prompt obedience. Existing runtime account metadata was available; missing credentials were not the blocker. No account identifiers or credentials are stored in this report.

No-tools options were inspected and applied: `tools=[]`, strict empty MCP, empty setting sources, empty skills/agents/plugins, disabled hooks/memory/attachments/background tasks/IDE attachment. Real preflight telemetry showed no memory files, agents or MCP tools/servers. Since no inference ran, this is configuration and initialization evidence, not proof of a complete effective model request. Managed policy can still apply.

## Implementation choices

Lua owns extmarks, buffer validation, undo and floats. Python owns SDK sessions and raw history. A single worker owns SDK connect/receive/disconnect scopes; cancellation arrives independently over stdin. Process EOF triggers disconnect and unsaved-session cleanup. There are no listening ports and no autonomous filesystem tools.

`getregionpos` and `getregion` supply native selection geometry, including virtual-column offsets. Partial tabs retain their unselected cells as spaces. Each row has its own target ID; all replacements validate before bottom-up application in one undo transaction. Target-content checks supplement moving extmarks.

Conversation manifests use exact runtime UUIDs and plugin-owned working directories. Advisory ownership locks prevent startup cleanup from sweeping live sessions. SDK `delete_session` scopes removal to those records. Saved sessions resume without restoring editor targets. Static system-prompt text lives in one resource, and prompt changes use the current custom-prompt `snapshot=false` form rather than editing recorded assistant history.

The unresolved hard-ceiling requirement dominates the outcome. Small source size does not compensate for a core acceptance failure.

## Reproducible line counts

Command:

```sh
wc -l lua/nvim-claude/*.lua python/*.py resources/system.txt tests/*.lua tests/*.py
```

| Category | Physical lines |
| --- | ---: |
| Lua implementation | 453 |
| Python implementation | 583 |
| Static system prompt | 44 |
| Focused regression checks | 109 |
| Total | 1189 |

Counts include blank/comment lines. They exclude documentation, generated bytecode, installed dependencies, private scratch exercises and the private configuration. Implementation plus its prompt is 1,080 lines; tests are counted separately.

## Installation

```lua
{
  "PsychedelicShayna/nvim-claude",
  branch = "experimental/benchmark-astra-6-high-neopi-20261021-7c93b2",
  main = "nvim-claude",
  opts = {},
}
```

The default currently produces an explicit unsupported-budget error instead of a model edit. README.md documents key overrides, authentication, persistence and the explicit model-default budget choice. The remote candidate and draft PR remain available for comparison; they are not merged into benchmark, nightly or master.
