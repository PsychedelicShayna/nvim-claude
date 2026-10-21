# nvim-claude

nvim-claude is a cursor-local Neovim companion for asking Claude questions, replacing a selection, and generating text at the cursor. It uses a small prompt float rather than a chat sidebar. Claude receives only the context attached to an explicit invocation and has no tools.

Lua owns editor state and applies completed edits. A local Python process hosts the official Claude Agent SDK and communicates with Neovim over Content-Length-framed JSON-RPC on stdio.

## Requirements

- Neovim 0.10 or newer. This candidate was exercised with Neovim 0.12.4.
- Python 3.10 or newer with `venv`. This candidate was exercised with Python 3.14.6.
- Network access on first backend use so the plugin can install the latest `claude-agent-sdk` release into its own virtual environment.

A separate Claude Code installation is not required. The SDK package includes its compatible CLI.

## Install this candidate

```lua
{
  "PsychedelicShayna/nvim-claude",
  branch = "experimental/benchmark-sol-5-6-medium-neopi-20261021T164636Z-6564093c",
  main = "nvim-claude",
  opts = {},
}
```

`setup()` registers `:NvClaude` and the mappings immediately. It does not contact the network, require authentication, or start Python. The first command that needs the backend creates a virtual environment under `stdpath("data")/nvim-claude/runtime`, installs the latest released SDK asynchronously, and starts one bridge process for that Neovim instance. Concurrent instances use an installation lock and never run from a half-created environment.

Run `:NvClaude update` when you deliberately want to upgrade an existing environment. `:NvClaude info` reports the resolved Python, SDK, and bundled CLI versions.

## Default interaction

| Mode | Mapping | Action |
| --- | --- | --- |
| Normal, Visual | `<leader>cc` | Replace the remembered or current selection |
| Normal, Visual | `<leader>c` | Short replacement mapping using native prefix resolution |
| Normal, Visual | `<leader>ca` | Ask generally or about the current selection |
| Normal | `<leader>ci` | Generate at the cursor |
| Normal | `<leader>cm` | Choose a runtime-announced model, effort, and context budget |
| Normal | `<leader>cM` | Enter a model expression manually |
| Normal | `<leader>cC` | Clear active working context |
| Normal | `<leader>cn` | Start a new conversation |
| Normal | `<leader>cS` | Toggle sticky persistence |
| Normal | `<leader>cs` | Save the active conversation |
| Normal | `<leader>cx` | Show model, usage, cache, retention, and runtime information |
| Normal | `<leader>cl` | Resume a saved conversation |

A prompt opens near the cursor in Insert mode. Use `Ctrl-S` from Insert or Normal mode to submit. Enter submits only in Normal mode, so Insert-mode Enter adds a line. Escape leaves Insert mode; a second Escape closes the prompt. In answer floats, `q` or Escape closes the window and restores the origin window when it still exists.

Visual replacement captures characterwise, linewise, or blockwise targets before the prompt opens. Results belong to that buffer and target even if focus changes. Extmarks follow unrelated edits, but nvim-claude compares the captured bytes before applying a result. A changed target, deleted buffer, cancellation, malformed response, or backend failure leaves source text alone and retains the result in a float where useful. A completed multi-segment edit is one undo step.

Normal-mode replacement reuses the last successfully replaced target in that buffer. Normal-mode ask reuses the last selected-ask target only while that selected-ask chain remains valid. `:NvClaude ask` is always general, and `:NvClaude ask previous` explicitly requests the previous selected-ask target.

## Configuration

Individual mappings can be replaced or disabled. `keys = false` disables all plugin mappings. Defaults do not overwrite a pre-existing user mapping; explicitly configured keys do.

```lua
{
  "PsychedelicShayna/nvim-claude",
  branch = "experimental/benchmark-sol-5-6-medium-neopi-20261021T164636Z-6564093c",
  main = "nvim-claude",
  opts = {
    keys = {
      replace = "<leader>i",
      replace_short = false,
      model = "<leader>I",
      generate_insert = "<C-g>",
    },
    model = "claude-haiku-5-5",
    effort = "low",
    context_limit_tokens = 100000,
  },
}
```

The key names are `replace`, `replace_short`, `ask`, `generate`, `generate_insert`, `model`, `model_manual`, `clear`, `new`, `sticky`, `save`, `info`, and `list`. Insert-mode generation is disabled by default.

An explicit interpreter can be supplied as `python = "/path/to/python3"`. It must support Python 3.10 or newer and the `venv` module.

## Commands

```text
:NvClaude ask [previous]
:NvClaude replace
:NvClaude generate
:NvClaude cancel
:NvClaude new
:NvClaude clear
:NvClaude save
:NvClaude sticky [on|off]
:NvClaude compact
:NvClaude list
:NvClaude info
:NvClaude model
:NvClaude model-manual
:NvClaude watermarks allow|remove|replace
:NvClaude system modify|default
:NvClaude login
:NvClaude update
```

`:NvClaude cancel` interrupts the current SDK turn and invalidates late events. `new`, `clear`, resume, and compaction also invalidate editor context baselines so the next file-aware request sends a new snapshot or marked excerpt.

`:NvClaude system modify` opens the shipped system prompt in a scratch tab. `:write` applies the override to the next turn by reconnecting to the same SDK session with a non-snapshotted custom prompt. The override lasts only for the current Neovim process. `system default` restores the shipped resource.

## Models and context budgets

The picker uses models and supported effort levels announced by the installed runtime. Manual entry remains available when discovery is missing or a model slug is not listed.

```text
claude-haiku-5-5[100k]:low
claude-opus-4-6[1m][500k]:high
claude-opus-4-6[1m][limit=500k]:high
```

The model, effort, and local budget are stored separately. A recognized native selector such as `[1m]` remains part of the runtime model ID. The last numeric bracket in a two-bracket expression is the local budget. `[limit=...]` is always local. A bare model retains the current effort and budget.

Before dispatch, the bridge combines runtime-reported context occupancy with a conservative UTF-8 byte upper bound, the complete custom system prompt, a 16,384-token runtime allowance, and an 8,192-token output reserve. It compacts early when the next turn approaches 72 percent of the selected budget and refuses a request whose upper bound still does not fit. This is deliberately conservative. `:NvClaude info` labels the policy rather than claiming that Claude Code exposes a native hard ceiling for every preset.

Whole-buffer snapshots are used when they fit. Later turns use an explicit unchanged marker or an append-only unified diff from the last accepted buffer baseline. Large buffers use a labeled excerpt around the intact target. The exact target and nearby boundary text are sent independently.

## Authentication and billing

The bridge uses the bundled runtime's existing supported authentication discovery. It does not copy refresh tokens and does not insert an API key. `:NvClaude login` opens the bundled CLI's official `claude auth login` flow in a terminal tab.

`:NvClaude info` reports the account mode announced by the runtime when available. An API key is a separately billed SDK path; the plugin never silently changes to it. Anthropic's Agent SDK overview restricts third-party products from offering claude.ai login or rate limits without approval, so this personal local integration does not promise subscription eligibility for other users.

## Conversations and local state

One conversation is active per Neovim instance. Unsaved conversations use an estimated one-hour reuse interval for first-party subscription mode and five minutes for API or cloud-provider mode. Expiry occurs before a new turn, never during one. No heartbeat requests are sent.

The SDK writes transcripts to its normal Claude Code project store. nvim-claude records only session IDs and exact transcript paths it created. On expiry or clean shutdown it deletes only its own unsaved transcript. Saved conversations remain resumable after restarting Neovim. Startup cleanup removes abandoned unsaved records only when their owning bridge process is no longer alive.

`save` marks the current conversation persistent. Sticky mode saves the current conversation and future conversations. Turning sticky mode off does not unsave existing records. `clear` resets active working context while preserving an already saved checkpoint. `new` detaches from the active conversation. `list` shows saved conversations newest first.

## Punctuation normalization

The default `watermarks allow` mode leaves output unchanged. The historical command name does not imply watermark detection.

- `remove` deletes em dash, en dash, curly single and double quotes, ellipsis, and non-breaking space.
- `replace` maps those characters to `-`, straight quotes, `...`, and ordinary space.

Normalization affects only displayed or inserted output. The SDK conversation retains the raw assistant reply. No other Unicode characters are changed.

## Development checks

```sh
nvim --headless -u NONE -l tests/headless.lua
PYTHONPATH=. python -m unittest tests.test_bridge
```

The headless check covers model-expression parsing, mapping ownership, UTF-8 target replacement, stale-result rejection, one-step undo, and punctuation policy. The Python check covers conservative budget accounting and refusal before dispatch.

## License

GNU General Public License version 3. See [LICENSE](LICENSE).
