# nvim-claude

Cursor-local Claude editing for Neovim. Select text and ask a question or replace it; generate at the cursor; ask general questions without attaching the current file. Lua owns editor state and applies completed edits. A Python bridge runs the official Claude Agent SDK with model tools disabled.

This is the independent Sol low / NeoPi benchmark candidate. It remains unmerged until the owner selects a candidate. The complete intended contract is in [SPEC.md](SPEC.md); the [run record](docs/agents/benchmark-result.md) distinguishes exercised behavior from gaps.

## Install

```lua
{
  'PsychedelicShayna/nvim-claude',
  branch = 'experimental/benchmark-sol-6-low-neopi-20261021T164632Z-fededfe3',
  main = 'nvim-claude',
  opts = {},
}
```

Neovim 0.12.4 and Python 3.14.6 were used for local checks. The SDK documents Python 3.10+; the minimum Neovim version has not been independently verified. Python needs `venv` and pip. Setup registers `:NvClaude` and mappings without Python, account login, or a network request. The first backend use asynchronously creates a plugin-owned virtual environment under `stdpath('data')` and installs the latest `claude-agent-sdk`. The SDK bundles Claude Code. Existing environments are reused, not upgraded silently. Set `opts = { python = '/path/to/python3' }` to choose Python.

Use `:NvClaude login` to run the bundled CLI's official authentication flow in a terminal. `:NvClaude info` displays the runtime's announced account and version metadata when available. This plugin does not copy credentials or select an API key on your behalf. Anthropic's [SDK terms](https://code.claude.com/docs/en/agent-sdk/overview) restrict third-party claude.ai login offerings; personal local login behavior does not promise a supported distribution model.

## Keys and commands

| Mode | Default | Action |
| --- | --- | --- |
| Normal, Visual | `<leader>c`, `<leader>cc` | Replace selected or remembered text |
| Normal, Visual | `<leader>ca` | Ask generally, or about a selection |
| Normal | `<leader>ci` | Generate at the cursor |
| Normal | `<leader>cm`, `<leader>cM` | Runtime model picker; manual model expression |
| Normal | `<leader>cC`, `<leader>cn` | Clear context; start a new conversation |
| Normal | `<leader>cS`, `<leader>cs` | Toggle sticky retention; save conversation |
| Normal | `<leader>cx`, `<leader>cl` | Session info; saved conversation list |

`opts.keys = { ask = '<leader>a', generate = false }` overrides and disables individual mappings. `opts.keys = false` disables all plugin mappings. Insert generation is opt-in with `keys = { generate_insert = '<leader>ci' }`. Defaults do not overwrite existing user mappings; an explicitly configured mapping does. Neovim's native mapping timeout governs the shorter `<leader>c` prefix. Setup does not change `timeoutlen`.

The prompt starts in Insert mode. Ctrl-S sends in either mode; Normal Enter sends; Insert Enter adds a line. Normal Escape closes it. Answer floats use `q` or Escape to close. `:NvClaude cancel` interrupts the active request without applying partial edits. Supported commands include `ask [previous]`, `replace`, `generate`, `model [manual]`, `save`, `sticky [on|off]`, `new`, `clear`, `compact`, `list`, `info`, `cancel`, `login`, `system modify|default`, and `watermarks allow|replace|remove`.

Manual model expressions include `claude-haiku-5-5[100k]:low` and `claude-opus-4-6[1m][500k]:high`. The model picker uses runtime-announced models and supported effort levels; manual entry remains available. Punctuation normalization changes only the displayed or inserted copy, not the SDK's raw assistant history. `watermarks` is the historical command name, not a detection claim.

## Context and retention

The initial model is `claude-haiku-5-5` with low effort and a requested 100k local budget. The bridge measures occupied context and estimates the next JSON input conservatively using UTF-8 bytes plus a 20k-token runtime reserve. It refuses requests close to the limit. The SDK does not expose an exact pre-dispatch count including all runtime-added content, so **this is not a verified hard pricing ceiling**. `:NvClaude info` labels the limit as unenforced. Selecting “model default” removes the local guard. A model's physical context window still applies.

Unsaved sessions are intended to expire on inactivity; saved conversations can be resumed through `:NvClaude list`. Cache lifetimes are estimates, not session storage or proof that Anthropic still holds a warm prefix. The session manifest lives under `stdpath('state')`. The current candidate does not yet delete all plugin-owned unsaved Claude Code transcripts on expiry or shutdown; do not rely on it for forensic erasure.

The runtime used for the local probe was Claude Agent SDK 0.2.170 with bundled Claude Code 2.1.306. A fresh first-use install can resolve newer versions. The runtime announced models and claude.ai authentication in that probe; see the run record for what was exercised.

## License

[GPL-3.0](LICENSE).
