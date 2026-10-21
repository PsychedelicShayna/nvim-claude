# Sol 6.1 NeoPi candidate

This is a complete, unmerged implementation candidate. The published implementation was installed and exercised through commit `7b57f1d`; the final delivery commit adds documentation only. Integration and comparison remain the owner's decision.

## Identity

- Model: `openai-codex/gpt-6.1-sol`.
- Harness: NeoPi. Its exact running version was not exposed by the available session metadata.
- Effort: the owner identified this original Sol run as xhigh. The harness did not expose an independent effort readback; no model or effort setting was changed.
- Baseline: `4c85985bf31be8a0ca03fe0cdc345708479d4f4c`, fast-forwarded from pinned nightly seed `c1cf1e11bb0e9768c4d62a5cfca1a39fc49789e3`.
- Candidate branch: `experimental/benchmark-sol-6-1-neopi-20261021-7b29e6`.
- Run issue: #11; benchmark preparation: #5.
- Implementation started at the observed UTC time `2026-10-21T14:56:54Z`. Final published runtime verification completed on 2026-10-21.
- No helpers, other candidates' worktrees, or private editor implementation were used. Neither `ctl` nor the question tool was used.

## Installed runtime

| Component | Observed version |
| --- | --- |
| Neovim | 0.12.4 |
| Python | 3.14.6 |
| claude-agent-sdk | 0.2.170 |
| Bundled Claude Code | 2.1.306 |
| lazy.nvim stable checkout | 85c7ff3711b730b4030d03144f6db6375044ae82 |

The runtime tuple was reported by the bridge inside the lazy.nvim-installed candidate. Model-backed checks used `claude-haiku-5-5`, requested effort `low`, thinking disabled, and a local prompt ceiling of 100,000 tokens. Initial SDK usage reported zero thinking tokens. Existing subscription authentication worked without copying credentials or substituting an API key.

The API minimums are Neovim 0.11 and Python 3.10 on POSIX systems. Only Linux and the versions above were exercised. macOS and the older supported versions remain unverified.

## Installation and editor evidence

lazy.nvim cloned `PsychedelicShayna/nvim-claude` by its actual published branch into isolated config/data/state/cache directories. The test configuration used `main = "nvim-claude"` and `opts = {}`, not a local `dir` entry. A fresh process loaded the installed Lua module from the plugin manager's clone. First backend use created its own SDK environment asynchronously; editor startup had registered commands and mappings without starting a bridge.

Actual terminal Neovim interaction exercised:

- Default Normal/Visual mappings, explicit overrides, individual disabling, `keys = false`, preservation of an existing user mapping, repeated setup, and unchanged native `timeoutlen`.
- A five-line prompt growing to five visible lines while typing paused, with no error. Insert Enter added newlines; Ctrl-S submitted; Normal Enter submitted a follow-up; Escape left Insert mode and a subsequent Normal Escape dismissed the prompt.
- Replacement of `...` by `quick` after an unrelated prefix line moved the target. A Normal follow-up changed the remembered result to `slow`. One undo restored `quick` without removing the prefix edit.
- Insertion into `abcd` at byte boundary 2 produced `abXcd` even after focus changed to another buffer. That other buffer stayed unchanged.
- A general answer hidden during streaming remained available through `NvClaude result`; its completed marker was retained, the source stayed unchanged, and `q` restored the origin window.
- Cancellation before edit completion made no source edit. An intervening change from `...` to `USER` was not overwritten; the unapplied `quick` result remained inspectable.
- A second submission retained its busy draft. The live check also exposed and led to correction of the prompt-resize bug described below.
- An actual empty SDK insertion preserved the source text, changed tick, and undo sequence.

The final published integration smoke then exercised real SDK output through native blockwise capture and application. A partially selected wide character produced `1X45` and ` Xbc` from `12345` and `界abc`. A partially selected tab preserved its five unselected cells and produced `a     Xc` and `123456X`.

That same installed process passed empty-parameter `info`, `save`, `list`, `new`, `resume`, and sticky controls. After resuming the saved SDK session, a general question correctly recalled the replacement letter `X`. It printed `PUBLISHED_SESSION_CONTROLS_AND_RESUMPTION_OK` and `PUBLISHED_BLOCKWISE_ACCEPTANCE_OK`, then shut down cleanly.

## Bridge, retention, and budget evidence

Real SDK probes established runtime-announced models and effort levels, empty effective tool/MCP/agent/skill/plugin sets, and no loaded memory files. `tools=[]`, strict empty MCP configuration, empty settings sources, safe mode, disabled hooks/memory/IDE attachment, and explicit built-in-plugin/doctor suppression are combined with runtime metadata checks.

Model-backed probes passed replacement, follow-up, actual `/compact` with `compact_boundary`, next-request system-prompt replacement using `snapshot=False`, save/clear/resume, restart resumption with the same runtime session ID, and ephemeral cleanup without deleting a saved checkpoint. A separate framed-process probe rejected a busy submission, canceled an active turn, answered `info`, completed a new turn with `AFTER_CANCEL`, and exited zero.

The budget probe exercised large fresh input, accumulated context, automatic runtime compaction, fresh snapshot or marked excerpt after compaction, and refusal of an impossible mandatory instruction before dispatch. Its observed values were:

| Probe | Observed result |
| --- | --- |
| Large fresh snapshot | Conservative bound 85,488; runtime context estimate 32,668 |
| Next explicitly invoked large document | Automatic compaction completed; current target remained intact |
| Oversized mandatory instruction | Bound 118,924 refused against 100,000 before dispatch |
| Restarted saved conversation | Recalled the last replacement word, `slow` |
| Ephemeral shutdown | Unsaved transcript removed; saved transcript retained |

Those numeric observations preceded the later virtual-cell prompt clarification, so they describe that prompt revision rather than a fixed size for every request.

The ceiling is a conservative host guard, not a provider-side input-token setting. A completed same-model prefix uses provider-reported input, cached input, and output counts. Fresh text uses UTF-8 byte bounds, with an explicit 16,384-token runtime/framing allowance. Uncertain delivery and model changes invalidate the measured prefix. Compaction requests are budgeted too; output reserves must fit physical context. This can reject text an exact tokenizer would fit. The allowance is not a formal guarantee about arbitrary future runtime or managed-policy changes, and the plugin does not advertise such a guarantee.

## Focused regressions

The following payloads ran under the workspace-required shared light lock and polite memory wrapper. That higher-priority requirement conflicted with the tournament's no-polite instruction and was disclosed before use. No build or full suite ran.

- `python -m unittest discover -s tests -p test_policy.py`: six cases passed, including shorthand/native selectors, malformed edit envelopes, literal deletion and whitespace, context transitions, normalization, and budget boundaries.
- `python -W error::ResourceWarning tests/test_storage.py`: three cases passed, covering all registered runtime IDs, unrelated-record preservation, live-owner leases, and saved checkpoints.
- Provisioned SDK Python running `tests/test_rpc.py`: one real-process case passed. An invalid array request did not disable subsequent save/list/new/resume or sticky transitions. It made no model/network calls.
- `nvim --headless -u NONE -i NONE -l tests/targets.lua`: passed native reversed UTF-8 selections, linewise replacement/deletion, partial tabs and wide cells, short virtual lines, stale targets, moved targets, literal insertion, no-op generation, and undo isolation.

Some earlier focused runs could not acquire the shared lock within their deadline. They were not counted as failures; the completed runs above supplied the final results.

## Implementation choices and corrections

Lua owns targets, floats, mappings, and undo. Python owns SDK clients, conversations, baselines, and budgets. The bridge uses one task-owned continuing SDK client and framed stdio, with no listening port. The model contract lives in one static resource. Invalid or clarifying edit output never becomes source text; raw SDK history is not punctuation-normalized.

The runtime needed investigation rather than SDK API guesses. `plugins=[]` still loaded bundled plugins until effective isolation was configured. Disabling all slash commands also disabled `/compact`; disabling the remaining doctor skill separately preserved real compaction. Provider prefix measurements avoided repeatedly charging a full serialized-history byte bound when budgeting later turns.

Live verification caught issues that fast smoke paths missed: native region ends can point at the final UTF-8 byte; empty API insertions created phantom undo entries; float repositioning required `relative`; and Lua empty tables became JSON arrays. The latter killed the Python worker before its error handler until object encoding and parameter validation were corrected. The model also correctly questioned a partial wide-cell target until the protocol explicitly distinguished selected virtual cells from the underlying UTF-8 span.

The only SDK-internal integration is its exact transcript-path resolver. That coupling is deliberate and version-sensitive; it avoids guessing unrelated session paths. Manifests and OS leases bound cleanup to registered records, including rotated session IDs.

## Limits and cleanup

Interactive OAuth login was not completed because existing credentials worked. The bundled `auth login --help` confirmed the official subscription-default flow. Explicit API billing, simultaneous installer stress, macOS, older supported runtimes, and the complete interactive picker-cancellation matrix were not exercised. No static model shortlist or fallback model substitutes for runtime discovery.

All owned verification editors and bridges were closed. Five disposable saved-test checkpoints and the exact initial SDK-only probe transcript were removed. The isolated lazy.nvim clone, SDK environments, and scratch scripts were deleted afterward. No other session, worktree, X11 instance, or unrelated Claude transcript was cleaned.

## Source size

Reproduce with `wc -l lua/nvim-claude/*.lua python/*.py prompts/system.txt tests/*.lua tests/*.py`.

| Scope | Lines |
| --- | ---: |
| Lua implementation | 802 |
| Python implementation | 896 |
| Static system prompt | 52 |
| Regression files | 330 |
| Total | 2,080 |

Implementation plus the static prompt is 1,750 lines, excluding tests. Counts include blank lines and comments, and exclude documentation, dependencies, caches, generated files, and vendored code. They are a reproducible size measure, not a comparison score or proof of maintainability.
