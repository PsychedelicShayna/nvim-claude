# Sol 6.1 low candidate

- Model: `openai-codex/gpt-6.1-sol`
- Reasoning: low, selected by the owner for this six-candidate round.
- Harness: NeoPi. Harness version not exposed in session metadata.
- Baseline: `4c85985bf31be8a0ca03fe0cdc345708479d4f4c`
- Pinned nightly seed: `c1cf1e11bb0e9768c4d62a5cfca1a39fc49789e3`
- Branch: `experimental/benchmark-sol-6-1-low-neopi-20261021-a7c9`
- Started: 2026-10-21T14:56:43Z

The owner explicitly selected low reasoning, superseding the launcher's earlier extra-high-only Sol comparison. No implementation helpers are used. This is an independent, unmerged candidate. Results are not yet established.

## Backend evidence

Installed latest released SDK 0.2.170 in a private Python 3.14.6 environment on the secondary drive. The bundled CLI reports 2.1.306. Its catalogue announces five entries, including Haiku 5.5. A real Haiku turn with thinking disabled succeeded using existing subscription authentication. No credentials were copied.

`tests/runtime.py` passed against the real framed bridge. It verified exact SDK-session resumption, immutable raw history, decoded replacement, next-request system-prompt override, manual compaction, and automatic early compaction. The compact command emitted a real `compact_boundary`. Normal turns report no tools, no plugins, and no skills. Runtime context reports no attached memory or agent definitions.

| Request | Conservative prompt bound | Actual prompt tokens | Effective ceiling |
| --- | ---: | ---: | ---: |
| Small replacement | 11,030 | 1,506 | 91,808 |
| Large fresh input | 86,789 | 39,393 | 91,808 |
| Continued after early compaction | 15,387 | 2,415 | 91,808 |

A 100,001-character instruction was refused before dispatch. The ceiling is below 100k because output is reserved within the configured runtime window. CLI versions other than 2.1.306 fail closed before capped model requests until their overhead is inspected. This is a conservative byte-bound policy, not an exact tokenizer or a claim about future upstream versions.

`tests/test_contracts.py` passed four focused cases. `tests/editor.lua` passed target and mapping regressions after replacing manual block geometry with Neovim's native region APIs. Clean lazy.nvim installation and the actual interactive UI remain to be exercised before delivery.
