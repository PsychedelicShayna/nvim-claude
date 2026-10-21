# nvim-claude

`nvim-claude` is a cursor-local Neovim plugin for deliberate editing with
Claude. It opens a small prompt near the cursor, streams questions into a
separate result float, and applies completed edits only to the captured target.
Claude receives no editing tools and never chooses files on its own.

Lua owns editor state. A local Python bridge owns the official Claude Agent SDK
client and communicates with Neovim over framed JSON-RPC on stdio.

## Requirements

- Neovim 0.10 or newer
- Python 3.10 or newer with the `venv` module
- A Claude authentication method supported by the bundled Claude Code runtime

A separate Claude Code installation is not required. On first backend use, the
plugin creates its own virtual environment and installs the latest released
`claude-agent-sdk`. Setup, commands, mappings, and prompt windows load before
that installation or authentication succeeds.

## Install this candidate

```lua
{
  "PsychedelicShayna/nvim-claude",
  branch = "experimental/benchmark-sol-5-6-xhigh-neopi-20261021T164649Z-20418304",
  main = "nvim-claude",
  opts = {},
}
```

Restart Neovim after changing candidate branches. The first command that needs
Claude may take a moment while the plugin creates its environment. Progress and
installation failures appear through `vim.notify`.

The desired personal workflow uses existing Claude Code authentication when the
runtime supports it. `:NvClaude login` opens the bundled CLI's official login
flow. The plugin does not copy refresh tokens and does not silently select API
key billing. Anthropic's restrictions on third-party login and subscription
usage still apply.

## Use it

Select text and press `<leader>cc` to replace it. Press `<leader>ca` to ask
about a selection without changing the source buffer. In Normal mode,
`<leader>ci` generates at the cursor.

The prompt starts in Insert mode.

- Insert or Normal mode `<C-s>` submits.
- Normal mode `<CR>` submits.
- Insert mode `<CR>` inserts a newline.
- Insert mode `<Esc>` returns to Normal mode.
- Normal mode `<Esc>` dismisses the prompt.

An answer or unapplied result stays in its own float. Press `q` or `<Esc>` in
Normal mode to hide it. Hiding a result does not cancel the request.
`:NvClaude cancel` interrupts the active request.

### Default mappings

| Mode | Mapping | Action |
| --- | --- | --- |
| Normal, Visual | `<leader>cc` | Replace the current or remembered target |
| Normal, Visual | `<leader>c` | Short replacement mapping |
| Normal, Visual | `<leader>ca` | Ask generally or about the selected target |
| Normal | `<leader>ci` | Generate at the cursor |
| Normal | `<leader>cm` | Choose a runtime-announced model |
| Normal | `<leader>cM` | Enter a model expression |
| Normal | `<leader>cC` | Clear active working context |
| Normal | `<leader>cn` | Start a new conversation |
| Normal | `<leader>cS` | Toggle sticky persistence |
| Normal | `<leader>cs` | Save the active conversation |
| Normal | `<leader>cx` | Show model, budget, usage, cache, and runtime data |
| Normal | `<leader>cl` | Resume a saved conversation |

Insert-mode generation is disabled by default. Native Neovim mapping resolution
governs the `<leader>c` prefix. The plugin does not change `timeoutlen` or
WhichKey settings.

Normal replacement reuses the last valid replacement target in the current
buffer. Normal ask continues a selected-ask chain only when that target remains
valid and no replacement, generation, general ask, or buffer switch ended the
chain. `:NvClaude ask` is always general. `:NvClaude ask previous` explicitly
requests the selected-ask target.

### Configuration

Every key can be replaced or disabled. `keys = false` disables all mappings.
Defaults do not overwrite an existing user mapping. An explicitly configured
mapping does.

```lua
{
  "PsychedelicShayna/nvim-claude",
  branch = "experimental/benchmark-sol-5-6-xhigh-neopi-20261021T164649Z-20418304",
  main = "nvim-claude",
  opts = {
    model = "claude-haiku-5-5",
    effort = "low",
    context_limit_tokens = 100000,
    punctuation = "allow",
    python = "/usr/bin/python",
    keys = {
      replace = "<leader>i",
      replace_short = false,
      ask = "<leader>ca",
      generate = "<leader>ci",
      generate_insert = false,
      model = "<leader>I",
      model_manual = "<leader>cM",
      clear = "<leader>cC",
      new = "<leader>cn",
      sticky = "<leader>cS",
      save = "<leader>cs",
      info = "<leader>cx",
      list = "<leader>cl",
    },
  },
}
```

`data_dir`, `venv_dir`, and `state_dir` can also be set. Their defaults use
Neovim's standard data and state directories.

## Commands

```text
:NvClaude ask [previous]
:NvClaude replace
:NvClaude generate
:NvClaude model [expression|manual]
:NvClaude new
:NvClaude clear
:NvClaude save
:NvClaude sticky [on|off]
:NvClaude list
:NvClaude compact
:NvClaude cancel
:NvClaude info
:NvClaude watermarks allow|remove|replace
:NvClaude system modify|default
:NvClaude login
:NvClaude update
```

`:NvClaude update` removes only the plugin-owned virtual environment after the
bridge stops. The next backend action recreates it and installs the latest SDK.

## Models and local budgets

The model picker uses the catalogue and effort metadata announced by the
installed runtime. If the runtime does not announce models, the plugin says so
and leaves manual entry available. It does not present a static shortlist as a
runtime catalogue.

Manual expressions keep the runtime model, effort, and plugin budget separate:

```text
claude-haiku-5-5[100k]:low
claude-opus-4-6[1m][500k]:high
claude-custom[limit=124k]:xhigh
```

Decimal `k` and `m` suffixes mean 1,000 and 1,000,000 tokens. The final numeric
group is the local budget when two groups are present. A recognized native
selector such as `[1m]` remains part of the runtime model. Arbitrary colons in
runtime IDs are preserved unless the final suffix is a recognized effort.

The picker offers model default and these local presets:

```text
50k, 90k, 100k, 124k, 150k, 164k, 200k, 224k, 256k,
258k, 274k, 278k, 300k, 374k, 378k, 384k, 412k, 456k,
500k, 512k, 600k, 650k, 700k, 750k, 800k, 850k, 900k,
950k, 980k
```

For a local budget, the bridge conservatively counts UTF-8 bytes, current
runtime occupancy, the system prompt, and an 8,192-token runtime allowance. It
compacts before the next request when the conservative total would cross the
limit, then refuses the request if it still cannot fit. The info window labels
this method and reports that the runtime's native hard ceiling has not been
verified. The plugin does not silently raise a configured limit.

## Targets and context

Each request owns its source buffer and extmarked target. Characterwise,
linewise, reversed, multibyte, and blockwise selections use zero-based UTF-8
byte coordinates internally. Blockwise rows remain separate model targets.
Newlines in blockwise replacements are rejected.

Before applying an edit, the plugin checks that the source buffer still exists,
is modifiable, and contains the captured target text. Unrelated edits can move
the extmarks. A change inside the target prevents application and leaves the
result visible. Successful multi-row edits join into one undo step.

The first selected or editing request sends a snapshot or a marked excerpt.
Later requests use an unchanged marker or an append-only diff when that is
smaller. A baseline advances only after the runtime accepts the turn.
Compaction and uncertain failures invalidate affected baselines.

General questions send no file context. The bridge serializes selected and
editing requests as JSON so document text cannot break a host delimiter.

## Conversations and storage

One conversation is active per Neovim instance. The bridge records only session
IDs it created. Unsaved sessions use a conservative five-minute cache estimate
when the runtime does not report authentication mode. Saved sessions do not
expire and can be resumed after restarting Neovim.

`save` preserves the active conversation. `sticky on` saves it and automatically
saves later conversations. `clear` starts with empty working context while
preserving a saved checkpoint. `new` starts another conversation. `compact`
sends the runtime's `/compact` command and resets file baselines after it
completes.

Claude Code writes SDK transcripts to its normal storage. The plugin manifest
tracks its own session IDs and removes only owned unsaved transcripts on expiry
or clean shutdown. It does not claim to erase provider retention or unrelated
Claude Code sessions.

## No-tools execution

The bridge configures:

- `tools = {}`
- empty MCP configuration with strict MCP enabled
- no user, project, or local setting sources
- no skills, plugins, or subagents
- no automatic file or IDE attachment

The info window reports configured isolation and any unexpected MCP tools or
agents found in runtime context metadata. Managed policy can still apply.

## Punctuation normalization

`:NvClaude watermarks` is a retained command name. This feature is punctuation
normalization, not authorship or watermark detection.

`allow` keeps output unchanged and is the default. `remove` deletes only em
dashes, en dashes, curly quotes, ellipses, and non-breaking spaces. `replace`
maps those characters to documented ASCII equivalents. Raw assistant history
is unchanged. Only displayed or inserted output is normalized.

## System prompt

`:NvClaude system modify` opens the current system prompt in a scratch buffer.
Write the buffer or press `<C-s>` to apply it to the next request in this
Neovim session. `:NvClaude system default` restores the packaged prompt.
Overrides do not persist across restarts.

## Development checks

```sh
NVIM_CLAUDE_ROOT="$PWD" nvim --headless -u NONE -l tests/lua/run.lua
python tests/test_bridge_protocol.py
```

The bridge protocol check requires `claude-agent-sdk` in that Python
environment. It initializes the bridge and proves an over-budget request is
rejected before a Claude process starts. It does not make a model request.

## License

GNU General Public License, version 3. See [LICENSE](LICENSE).
