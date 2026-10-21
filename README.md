# nvim-claude

Cursor-local collaboration with Claude in Neovim. Select text, open a small prompt, enter an instruction, and keep editing while the response runs. Ask answers stay in a separate float. Replacement and generation apply completed output to the captured target, not the current cursor.

This is the independent **Sol 6.1 low / NeoPi** benchmark candidate. It is not merged into nightly or master. The shared behavior contract is [SPEC.md](SPEC.md), and the run's evidence is in [docs/agents/benchmark-result.md](docs/agents/benchmark-result.md).

## Install

Requirements: Unix, Neovim 0.12+, Python 3.10+ with `venv` and pip, and network access for first-use installation. Verified here with Neovim 0.12.4 and Python 3.14.6. Older Python versions are the SDK's declared minimum, not versions exercised in this run.

```lua
{
  "PsychedelicShayna/nvim-claude",
  branch = "experimental/benchmark-sol-6-1-low-neopi-20261021-a7c9",
  main = "nvim-claude",
  opts = {},
}
```

Restart Neovim when switching candidate branches. `setup()` registers commands and mappings immediately. It does not install packages, start Claude, or require authentication. The first backend action asynchronously creates a private Python environment and installs the latest released `claude-agent-sdk`, including its bundled CLI. No separate Claude Code installation, private config, or `inf` executable is needed.

The venv is under `stdpath("data")/nvim-claude/venv`; manifests are under `stdpath("state")/nvim-claude/conversations`. Runtime transcripts use Claude Code's normal storage, with exact session IDs recorded by the plugin. Installation is serialized with an OS file lock. `:NvClaude update` explicitly upgrades the existing environment. Failed installation never writes its ready marker.

The latest dependency resolved to SDK **0.2.170**, bundled CLI **2.1.306**. Because a newer runtime could change hidden input overhead, capped model requests fail closed on unverified CLI versions. Menus, login, and diagnostics still work. Updating the SDK is explicit; the version guard is not an SDK pin.

## Use

The prompt opens near the cursor in Insert mode. Enter inserts a newline. Ctrl-S submits in Insert or Normal mode; Enter submits in Normal mode. Escape leaves Insert mode, then a second Escape dismisses the prompt. These are buffer-local mappings.

| Modes | Default | Action |
| --- | --- | --- |
| Normal, Visual | `<leader>cc`, `<leader>c` | Replace the selected or remembered target |
| Normal, Visual | `<leader>ca` | Ask generally, about a selection, or follow up on the last selected ask |
| Normal | `<leader>ci` | Generate before the captured cursor character |
| Insert | disabled | Optional insertion at the actual insertion boundary |
| Normal | `<leader>cm` | Runtime-announced model, effort, then context ceiling |
| Normal | `<leader>cM` | Manual model expression |
| Normal | `<leader>cC` | Clear working conversation, retain saved checkpoints |
| Normal | `<leader>cn` | Start a new conversation |
| Normal | `<leader>cS` | Toggle sticky persistence |
| Normal | `<leader>cs` | Save current conversation and future completed turns |
| Normal | `<leader>cx` | Information float |
| Normal | `<leader>cl` | Saved conversation picker |

Normal replacement without a valid target reports that a selection is needed. After replacement, the remembered target is the newly inserted text. Normal ask continues a selected-ask chain only in the same buffer, while the target remains valid and no replacement or generation has intervened. Model menus do not end the chain. `:NvClaude ask` is always general; `:NvClaude ask previous` explicitly asks about the previous selected-ask target.

Mappings use native prefix resolution. `<leader>c` waits while a longer mapping remains possible; the plugin does not change `timeoutlen` or WhichKey. Existing user mappings are preserved unless the corresponding key option is explicitly supplied. Repeated setup removes only mappings still owned by this plugin.

```lua
opts = {
  keys = {
    replace = "<leader>rr",
    replace_short = false,
    generate = "<leader>i",
    generate_insert = "<C-g>",
    model = "<leader>I",
  },
}
-- keys = false disables all plugin mappings.
-- Every key option accepts a replacement string or false.
```

Key option names are `replace`, `replace_short`, `ask`, `generate`, `generate_insert`, `model`, `model_manual`, `clear`, `new`, `sticky`, `save`, `info`, and `list`.

Ask output streams without taking focus away from your source. Use ordinary window navigation to enter the answer. `q` or Escape in Normal mode closes an answer and returns to its origin. Closing it does not cancel the request. `:NvClaude answer` reopens the retained result, including the current stream. You can select answer text and explicitly ask about or replace it.

Extmarks track the source buffer and target. The plugin verifies target contents again before applying. A stale, deleted, or nonmodifiable target leaves the result in a float instead of overwriting your changes. Characterwise, reversed, linewise, and native virtual-cell block selections use Neovim's own region semantics. Partial tabs preserve unselected cells as spaces. Block replacements remain on their rows and apply bottom-up as one undo step. Edit JSON is validated before any buffer mutation. Whitespace is not trimmed; empty text is an intentional deletion.

## Commands

`:NvClaude` provides completion. With no argument, it opens a general ask prompt.

| Command | Behavior |
| --- | --- |
| `ask [previous]`, `replace`, `generate` | Open an operation prompt |
| `cancel` | Interrupt the active request and reject late output |
| `answer` | Reopen the most recent answer or retained failure result |
| `model [manual\|expression]` | Picker, manual input, or direct model expression |
| `new`, `clear` | Detach working context; do not delete saved checkpoints |
| `save` | Persist this conversation, including subsequent completed turns |
| `sticky [on\|off]` | Automatically save current and future conversations |
| `compact` | Run actual `/compact`; require a runtime completion boundary |
| `list`, `resume <id>` | Pick or resume an exact saved SDK session |
| `info` | Model, effective context, usage, retention, cache estimate, versions, billing |
| `system modify` | Edit the session-local system prompt in a scratch buffer; `:write` applies it |
| `system default` | Restore the shipped prompt |
| `watermarks allow\|replace\|remove` | Output punctuation policy |
| `login` | Open the bundled CLI's official `auth login` in a terminal |
| `update` | Explicitly upgrade the private SDK environment |

A second submission during a turn retains its prompt draft and reports busy. New, clear, and resume cancel an active edit before switching context. Model and prompt changes run between turns. Prompt changes reconnect the same SDK session with `snapshot=False`, keeping raw history and making the new prompt effective on the next request. This can invalidate provider prefix caching.

## Models and budgets

The initial configuration is:

```lua
opts = {
  model_config = {
    model = "claude-haiku-5-5",
    effort = "low",
    context_limit_tokens = 100000,
  },
}
```

Thinking is disabled for this quick-edit workflow. Runtime-announced effort choices remain separate from thinking mode. Manual model IDs remain usable when absent from discovery, but their effort support is labeled unverified. There is no fallback model.

Examples:

```text
claude-haiku-5-5[100k]:low
claude-opus-4-6[1m][500k]:high
claude-opus-4-6[1m]:high
vendor:model[limit=90k]
```

The last recognized effort suffix is parsed separately. The last numeric bracket is a local budget when there are two. Recognized native selectors remain part of the runtime model ID; a lone recognized native selector chooses model-default local budgeting. `[limit=100k]` is always a local budget. Unrecognized nonnumeric suffixes are preserved. A plain model ID retains the current local budget and supported effort. Separate `model_config` fields bypass shorthand parsing.

The picker offers model default and these decimal-token presets:

```text
50k, 90k, 100k, 124k, 150k, 164k, 200k, 224k, 256k,
258k, 274k, 278k, 300k, 374k, 378k, 384k, 412k, 456k,
500k, 512k, 600k, 650k, 700k, 750k, 800k, 850k, 900k,
950k, 980k
```

The dispatch guard bounds text with **UTF-8 bytes**, not a characters-divided-by-four estimate. It includes the system prompt, current SDK transcript chain, the serialized next request, and an 8,192-token runtime allowance. Tools, skills, plugins, external memory, and project settings are disabled for ordinary editing turns. Runtime context metadata is checked for unexpected attached context. The installed 2.1.306 runtime's observed overhead fits this allowance; other versions are refused before a capped model request.

An additional 8,192 tokens are reserved for output within the runtime-reported window. With the default 100k runtime compaction window, this makes the effective prompt ceiling **91,808**, conservatively below the requested 100k. `info` reports the actual last prompt count separately from the conservative bound. This deliberately trades available context for a defensible ceiling. It does not promise that a provider's future tokenizer or hidden runtime behavior can never change.

The bridge compacts before the next bound crosses 65% of the effective ceiling. It checks the compaction request's bound too. Compaction temporarily reconnects with native commands enabled, still without model tools, then returns to ordinary command-disabled editing. A successful boundary invalidates buffer baselines. Compaction is lossy and costs tokens. If it is too late to compact within the cap, the request is refused rather than silently increasing the cap.

Initial context is a snapshot. Later context uses an explicit unchanged marker or an append-only unified diff from the last accepted baseline, preferring a snapshot when smaller. After uncertain delivery, resumption, or compaction, the next context is fresh. A large local task may receive an explicitly incomplete excerpt around its intact target; missing regions are marked unknown. Set `context = "full"` to refuse oversized whole-file context rather than excerpt it. Targets and mandatory instructions are never truncated.

## Authentication and persistence

The plugin uses the bundled CLI's existing supported authentication. This run exercised an existing Claude Max session without copying credentials. `:NvClaude login` delegates to the official login flow. Default `billing = "subscription"` suppresses API-key and cloud-provider credentials in the child environment so they cannot become a silent paid fallback. To deliberately use API credentials, set `billing = "api"`; that is a billing decision, not an authentication repair.

Anthropic's [SDK overview](https://code.claude.com/docs/en/agent-sdk/overview) restricts third-party use of claude.ai login without prior approval. Personal authentication working here does not establish distribution eligibility or immunity from account restrictions.

Unsaved conversations use SDK-backed temporary transcripts. The plugin's manifest records exact IDs and holds an OS lock while a bridge owns them. New, expiry, clean shutdown, or startup recovery deletes only unsaved plugin-owned sessions. Saved sessions resume after a restart, using the same SDK ID. Another live Neovim cannot claim the same saved session. `clear` preserves the previous saved checkpoint and starts detached working context. Sticky off never unsaves an existing conversation.

The estimated ephemeral lifetime is one hour for subscription mode or five minutes for explicit API mode, updated from cache-creation usage when available. Expiry happens only before a new turn, never during one. Saved sessions do not expire. There are no keep-warm requests. Provider cache deletion, diagnostic retention, and forensic erasure are not promised.

## Punctuation

Default `watermarks allow` preserves output. `replace` maps em/en dashes to `-`, curly single quotes to `'`, curly double quotes to `"`, ellipsis to `...`, and nonbreaking space to ordinary space. `remove` deletes exactly those characters and may join words or break code. It is opt-in. Other Unicode, including zero-width characters, passes through.

Normalization touches only displayed or inserted text, never raw SDK history. The next buffer diff describes what actually reached the editor. This is punctuation normalization, not watermark detection or an authorship claim.

## Development verification

- `python tests/test_contracts.py` checks parsing, result validation, context revisions, excerpts, and Unicode normalization.
- `nvim --headless -u NONE -l tests/editor.lua` checks editor-owned targets, stale edits, undo, block cells, captured insertion, and key ownership.
- With the private SDK interpreter, `python tests/runtime.py --state <disposable-directory>` exercises real sequential Haiku calls, persistence, prompt changes, budget refusal, and manual/automatic compaction. It uses account access and deletes the test directory's conversation records. Never point it at real plugin state.

The plugin is Lua and Python. There is no native build or separate server port. Lua and Python exchange JSON-RPC frames over the bridge's stdio. [LICENSE](LICENSE) is GPL-3.0; the SDK's bundled Claude Code runtime has its own terms.
