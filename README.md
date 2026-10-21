# nvim-claude

nvim-claude is a cursor-local Neovim companion backed by the Python Claude Agent SDK. It opens a small prompt next to the cursor, streams answers into a separate float, and applies completed edits only to the captured range. Claude receives no tools and cannot read files that Neovim did not send.

## Requirements

- Neovim 0.10 or newer. This candidate was verified with Neovim 0.12.4.
- Python 3.10 or newer with `venv`. Provisioning was verified with Python 3.14.6.
- An Anthropic account or API credential supported by Claude Code.

A separate Claude Code installation is not required. On first backend use, the plugin asynchronously creates a virtual environment under Neovim's data directory and installs the latest `claude-agent-sdk`. Commands, mappings, and prompt windows work before provisioning or authentication succeeds.

## Installation

This benchmark candidate can be installed directly by branch:

```lua
{
  "PsychedelicShayna/nvim-claude",
  branch = "experimental/benchmark-sol-5-6-low-neopi-20261021T164631Z-8b31e6f4",
  main = "nvim-claude",
  opts = {},
}
```

The default model configuration is `claude-haiku-5-5`, low effort, with a conservative 100,000-token local ceiling.

## Use

Select text and press `<leader>cc` or `<leader>c` to replace it. Press `<leader>ca` to ask about a selection without changing the source buffer. In Normal mode, `<leader>ca` continues the last valid selected-ask chain; `:NvClaude ask` always asks generally. Press `<leader>ci` to generate at the cursor.

The prompt starts in Insert mode. Insert-mode Enter adds a line. Escape enters Normal mode, Normal-mode Enter submits, Ctrl-S submits from either mode, and a second Normal-mode Escape dismisses the prompt.

| Mode | Default | Action |
| --- | --- | --- |
| Normal, Visual | `<leader>cc` | Replace selection or remembered replacement target |
| Normal, Visual | `<leader>c` | Short replacement mapping using native prefix timing |
| Normal, Visual | `<leader>ca` | Ask generally or about the selected target |
| Normal | `<leader>ci` | Generate at the captured cursor boundary |
| Normal | `<leader>cm` | Pick a runtime-announced model, effort, and limit |
| Normal | `<leader>cM` | Enter a model expression manually |
| Normal | `<leader>cC` | Clear active working context |
| Normal | `<leader>cn` | Start a new conversation |
| Normal | `<leader>cS` | Toggle sticky persistence |
| Normal | `<leader>cs` | Save the active conversation |
| Normal | `<leader>cx` | Show model, usage, cache, runtime, and retention information |
| Normal | `<leader>cl` | Resume a saved conversation |

Insert-mode generation is disabled by default. Existing user mappings are preserved unless that key is explicitly configured. Override or disable mappings through the shared option contract:

```lua
opts = {
  keys = {
    replace = "<leader>i",
    replace_short = false,
    generate = "<leader>g",
    generate_insert = "<C-g>",
  },
}
```

Set `keys = false` to disable all plugin mappings. Every action remains available through `:NvClaude`.

## Commands

```text
:NvClaude ask [previous]
:NvClaude replace
:NvClaude generate
:NvClaude cancel
:NvClaude clear
:NvClaude new
:NvClaude save
:NvClaude sticky [on|off]
:NvClaude compact
:NvClaude list
:NvClaude info
:NvClaude model
:NvClaude model manual
:NvClaude watermarks allow|remove|replace
:NvClaude system modify|default
:NvClaude login
```

`system modify` opens the built-in prompt in a scratch buffer. Write that buffer to apply the override to the next request in this Neovim instance. `system default` restores the shipped prompt.

The `watermarks` command controls punctuation presentation, not authorship detection. `allow` is the default. `replace` maps em/en dashes, curly quotes, ellipsis, and non-breaking space to documented ASCII equivalents. `remove` deletes exactly that same set. Raw assistant history remains unchanged.

## Models and local limits

Manual expressions keep runtime selectors, effort, and the plugin limit separate:

```text
claude-haiku-5-5[100k]:low
claude-opus-4-6[1m][500k]:high
claude-haiku-5-5[limit=90000]:low
```

The picker uses model and effort metadata announced by the installed runtime. If the runtime does not announce a catalogue, the plugin says so and opens manual entry rather than presenting a static list as authoritative.

Before dispatch, the bridge combines measured context occupancy with a conservative upper bound of one token per UTF-8 byte and a 20,000-token runtime/output reserve. It requests compaction before a continued request that would exceed the configured ceiling and refuses a request that still cannot fit. `:NvClaude info` reports the measured usage separately from cumulative usage and labels cache timing as an estimate.

## Authentication and billing

`:NvClaude login` opens the bundled Claude Code login flow in a terminal buffer. The bridge otherwise uses credentials that the official runtime already supports. It does not copy refresh tokens, implement OAuth, or silently switch to an API key. If `ANTHROPIC_API_KEY` is present, Claude Code may use API billing; the plugin does not add that variable.

Anthropic's SDK terms restrict third-party use of claude.ai login and subscription rate limits without approval. This plugin exposes the official runtime path for personal local use but cannot promise account eligibility or a particular billing mode.

## Editor and session behavior

Lua owns windows, extmarks, targets, context snapshots/diffs, validation, and undo. The Python bridge owns the SDK client, streaming, interruption, usage, session IDs, and a plugin manifest in Neovim's state directory. JSON-RPC uses Content-Length framing over stdio. Prompt text is passed as an argv-safe protocol payload, never interpolated into a shell command.

Selections use UTF-8 byte coordinates and live extmarks. Before applying an edit, the plugin compares the captured text against the current target. An intervening edit inside the target leaves the generated result in a float instead of overwriting the buffer. Completed multi-segment edits are applied bottom-up as one undo block.

Saved conversations retain their SDK session ID and plugin transcript for resumption. Unsaved sessions expire after the estimated cache interval and are deleted only by their recorded session ID. The plugin never sweeps unrelated Claude Code sessions. General questions send no buffer. Selected asks and edits send a snapshot, an append-only diff from an accepted baseline, an unchanged marker, or a labeled excerpt when a full file is too large.

## Development checks

```sh
nvim --clean --headless -u NONE '+luafile tests/lua_spec.lua' +qa!
python -m unittest tests/test_bridge.py
```

See [SPEC.md](SPEC.md) for the complete behavior contract and [docs/agents/benchmark-result.md](docs/agents/benchmark-result.md) for candidate-specific verification and runtime limitations.

## License

GNU General Public License, version 3. See [LICENSE](LICENSE).
