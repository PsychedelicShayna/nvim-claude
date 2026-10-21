# Sol 6.1 low candidate

## Identity

- Model: `openai-codex/gpt-6.1-sol`
- Reasoning: low, explicitly selected by the owner for this six-candidate round.
- Harness: NeoPi. Its version was not exposed in session metadata.
- Baseline: `4c85985bf31be8a0ca03fe0cdc345708479d4f4c`
- Pinned nightly seed: `c1cf1e11bb0e9768c4d62a5cfca1a39fc49789e3`
- Branch: `experimental/benchmark-sol-6-1-low-neopi-20261021-a7c9`
- Run issue: #9. Benchmark preparation: #5.
- Started: 2026-10-21T14:56:43Z.

The owner's low-effort selection superseded the launcher's earlier extra-high-only Sol comparison. No subagents, control socket, other candidate worktrees, private Neovim configuration, or other terminal sessions were used. A separate randomly named tmux server held only this run's disposable Neovim UI check.

## Delivered behavior

The branch exposes `require("nvim-claude").setup(opts)` and installs by repository and branch through lazy.nvim. Lua owns prompts, answer floats, native mappings, extmark targets, source revisions, and undo. A lazy Python actor owns one SDK client and serializes conversation transitions over Content-Length-framed JSON-RPC stdio. There is no listening port, separate Claude installation, file-editing tool, or project crawler.

The README documents the actual branch, all key overrides, authentication, commands, model expressions, budget behavior, and runtime limitations. The comparison PR remains draft and unmerged. Owner selection is required before any integration.

## Runtime and authentication

| Component | Observed version |
| --- | --- |
| Neovim | 0.12.4 |
| Python | 3.14.6 |
| Latest released claude-agent-sdk at setup | 0.2.170 |
| SDK-bundled Claude Code | 2.1.306 |

Unix is required by the installation and ownership locks. The documented Neovim minimum is 0.12. Python 3.10+ is the SDK's declared minimum; only the versions above were exercised here.

Real requests used `claude-haiku-5-5`, effort low, thinking disabled, and an existing Claude Max authentication session. Credentials were neither copied nor placed in the disposable configuration. The bundled executable's `auth --help` confirmed its official login command. A fresh browser login and explicit API/cloud billing were not exercised. Default subscription mode suppresses API-key and cloud-provider fallback credentials in the SDK child environment.

The runtime announced five model entries. Its initialization for ordinary editing turns reported `tools: []`, `skills: []`, and `plugins: []`; context metadata reported no attached memory files, MCP tools, system tools, or agent definitions. Built-in agent profiles remain in the runtime's server catalogue, but there is no Agent tool through which the model could invoke them. Managed policy is not bypassed.

## Executed verification

### Focused checks

Executed under the shared light lock and the required resource relay, serially:

```text
python tests/test_contracts.py
nvim --headless -u NONE -l tests/editor.lua
<private-sdk-python> tests/runtime.py --state <run-specific-disposable-state>
```

All passed. No full suite, native build, browser fleet, or parallel SDK process group was launched.

The pure checks cover native model selectors, separate local budgets, colon-bearing IDs, invalid replacement sets, deliberate deletion, block newline rejection, context revisions, bounded excerpts, and punctuation normalization.

Editor regressions cover unrelated edits moving a target, stale-target refusal, one-step undo without absorbing unrelated edits, reversed UTF-8 selection, combining characters, reversed exclusive selection, linewise replacement, partial tabs, block follow-up targets, insertion after focus changes, complete UTF-8 boundary snippets, existing key preservation, explicit overrides, disabled keys, and repeated setup.

The real stdio bridge check covers a runtime-announced Haiku model, decoded replacement, exact SDK-session resumption with unchanged raw history, file-free general asks, saved-checkpoint retention across clear, next-request system-prompt replacement, refusal before dispatch, and manual and automatic native compaction. Compaction required a real `compact_boundary`, not an ordinary answer claiming to summarize.

### Budget evidence

| Request | Conservative prompt bound | Actual prompt tokens including cached input | Effective ceiling |
| --- | ---: | ---: | ---: |
| Small replacement | 11,030 | 1,506 | 91,808 |
| Large fresh input | 86,789 | 39,393 | 91,808 |
| Continued after early compaction | 15,032 | 2,284 | 91,808 |

A 100,001-character instruction was refused before dispatch. The dispatch bound includes UTF-8 bytes of the system prompt, current SDK transcript chain, serialized next request, and an 8,192-token runtime allowance. It is deliberately more conservative than a token estimate. A further 8,192 tokens are reserved for output inside the configured runtime window. Thus the default effective prompt ceiling is below the requested 100k.

The bridge compacts early, checks the compaction request's bound, then invalidates buffer baselines. It refuses a request if safe compaction is no longer possible. CLI versions other than 2.1.306 fail closed before capped model requests until their added input is inspected. This is not an exact tokenizer, evidence of an exactly-100k-token provider request, or a guarantee about future upstream runtimes. The latest dependency is installed rather than pinned; unknown overhead is an explicit unsupported-budget error.

### Clean published installation and actual TUI

A disposable XDG config/data/state/cache tree on the secondary drive installed `PsychedelicShayna/nvim-claude` at this candidate branch using lazy.nvim, with `main = "nvim-claude"` and `opts = {}`. No local `dir` plugin entry or private configuration was involved. After a fresh Neovim process, commands and default mappings existed, explicit overrides and disabled mappings worked, and no bridge or venv existed before first backend use.

First use created its own venv and installed the latest SDK. The actual TUI verified:

- A small cursor-local prompt, operation/model title, Insert-mode newline, Ctrl-S submission, and Normal-mode Enter submission.
- Source typing during fresh provisioning. The unrelated line remained intact after the model edit.
- Replacement of only `...` with `quick`, followed by Normal-mode refinement of the remembered new target to `QUICK`.
- Selected ask and selected-ask follow-up, answering `QUICK` and `quick` in separate floats while leaving the source uppercase.
- A general ask with no document/context/targets, confirmed in the plugin-owned manifest.
- Answer closure and focus restoration, retained output, busy-draft preservation, and interruption of an active insertion without applying partial output.
- Saving, full Neovim shutdown, restarting the installed branch, and resuming the same SDK session. The resumed model answered `QUICK` from its prior history in a new empty editor buffer.
- Restoring a saved manual selector `haiku` into the prompt title instead of leaving the startup default selector visible.
- Separate Insert-mode Escape and Normal-mode Escape prompt behavior.

The TUI checks found two real defects that headless checks did not: pip stderr notifications and multiline control acknowledgements caused hit-enter prompts. Both were corrected and re-exercised on the published branch. Normal installer progress is now a single status message, stderr is bounded and shown on failure, and routine session confirmations are single-line.

## Design choices and remaining verification limits

- Native `getregionpos` and `getregion` own selection semantics. Manual virtual-column geometry was replaced after the partial-tab check exposed its weakness. Unselected cells around a partial tab are preserved as spaces.
- Remembered replacement targets are per-buffer. A selected-ask chain ends when entering another ordinary source buffer. Outstanding results validate both live positions and captured text.
- SDK transcripts and raw logical history are separate from presentation output. Unified diffs mark missing final newlines; unchanged context retains the revision actually accepted by the runtime.
- File locks establish live ownership of exact session manifests. Deletion uses the SDK's public session deletion function with a recorded ID and cwd, never a sweep of unrelated sessions. Empty lock files may remain; they contain no history.
- Compaction temporarily reconnects the same session with native commands enabled, still with no model tools. Ordinary model turns disable commands and skills. System-prompt changes use the supported custom prompt form with `snapshot=False` and resume the exact session rather than replaying a fabricated transcript.
- Provider cache warmth and inactivity countdowns are estimates. No heartbeat inference occurs. Actual one-hour/five-minute expiry was not wall-clock tested, and abandoned-owner recovery was not crash-injected. Save/resume and ordinary shutdown cleanup were exercised.
- Only Haiku inference was exercised. Other announced models and effort levels are metadata-backed choices, not inference-tested claims. Unknown manual IDs are passed through without a fallback and labeled unverified for effort support.
- First-use network failure, every supported older interpreter, Windows, account login, and API/cloud billing were not exercised. Windows is not advertised as supported.

## Source size

Reproduce with:

```sh
wc -l lua/nvim-claude/*.lua python/*.py resources/system.txt \
  tests/test_contracts.py tests/editor.lua tests/runtime.py
```

| Category | Lines |
| --- | ---: |
| Lua implementation | 695 |
| Python implementation | 710 |
| Static system prompt | 44 |
| Focused and opt-in live checks | 270 |
| Total | 1,719 |

Counts exclude documentation, generated files, dependencies, and caches. The implementation plus prompt is 1,449 lines. These are source line counts, not a quality score or measured performance comparison against other candidates.

## Retention

The remote candidate branch and draft comparison PR are the retained artifacts. The delivery procedure verifies the pushed ref before removing this run's local topic worktree, local branch, disposable XDG environment, and test SDK environment. Saved test transcripts are deleted by their recorded IDs before their disposable manifests are removed. No candidate is merged or selected by this run.
