# nvim-claude

A cursor-local Neovim companion backed by the official Python Claude Agent SDK. Ask a question in a float, transform a selection, or insert text at a captured cursor boundary. Claude has no editing tools. Lua applies a completed, validated edit once.

This is the independent **Sol 6.1 high / NeoPi benchmark candidate**. It remains unmerged pending the owner's comparison.

## Install

Requires Neovim **0.12+**, Python **3.10+** with `venv` and pip, and network access for first-use provisioning. Verified on Neovim 0.12.4 and Python 3.14.6 on Linux. Linux/macOS are supported; Windows native is not currently supported by the POSIX environment and file-lock implementation.

```lua
{
  "PsychedelicShayna/nvim-claude",
  branch = "experimental/benchmark-sol-6-1-high-neopi-20261021T161659Z",
  main = "nvim-claude",
  opts = {},
}
```

Restart Neovim when switching candidates. Setup registers commands and mappings immediately, without network or authentication. Opening the first prompt or another backend action asynchronously creates a plugin-owned Python environment and installs the latest released `claude-agent-sdk`. No separate Claude Code installation, private config, or developer checkout is needed. A prompt does not submit a model request until you submit it.

The installed SDK is reused. `:NvClaude update` explicitly installs a new isolated SDK generation. Install locking prevents editors from sharing a half-created environment. Old generations remain available to editors already using them; after closing those editors, unused `sdk-*` directories in the plugin data directory may be removed. `:NvClaude info` reports the resolved versions. This run resolved SDK 0.2.170 and bundled CLI 2.1.306.

## Authentication and billing

`:NvClaude login` opens the **bundled CLI's official `auth login` flow** in a terminal split. The runtime uses its normal credential discovery. This plugin does not copy tokens, implement OAuth, or create a second credential store. Commands and floats remain available when login is missing.

Default `auth_mode = "subscription"` refuses inherited API/cloud credentials instead of silently changing billing. To deliberately use API credentials, configure `auth_mode = "api"`; API usage is billed separately. Runtime account metadata is used to label the estimated cache lifetime. Subscription entitlement is determined by Anthropic, not this plugin.

Anthropic's [SDK overview](https://code.claude.com/docs/en/agent-sdk/overview) restricts third-party products offering claude.ai login/rate limits without approval and directs integrations to API-key authentication. A supported local runtime login is not a promise about eligibility or account restrictions.

## Interaction

Select text and use `<leader>cc`, enter an instruction in the small cursor-local float, then press Ctrl-S. The source remains editable while a request runs. Ask answers stream into a separate float; replacements apply only on successful completion. Invalid output, cancellation, or a changed/deleted source never applies partial text. A result that cannot be applied is retained in a float.

Prompt keys are buffer-local:

- Ctrl-S submits from Insert or Normal mode.
- Enter submits in Normal mode and inserts a newline in Insert mode.
- Escape leaves Insert mode; Escape again dismisses the prompt and restores focus.
- In answer floats, `q` or Escape closes the window. Closing hides the answer without cancelling the request. `:NvClaude cancel` interrupts it explicitly.

Characterwise, reversed, linewise, and blockwise targets use native Neovim region semantics. Extmarks follow unrelated edits; changing a target invalidates it, even if subsequently undone. Block targets preserve unselected tab/wide-character cells. One undo reverses the complete applied edit. A successful replacement remembers its new span for follow-ups. Normal generation inserts before the cursor character; Insert generation captures the insertion boundary.

## Default keys

| Option | Mapping | Modes / action |
| --- | --- | --- |
| `replace` | `<leader>cc` | Normal/Visual replacement |
| `replace_short` | `<leader>c` | Normal/Visual replacement |
| `ask` | `<leader>ca` | Normal/Visual question |
| `generate` | `<leader>ci` | Normal insertion |
| `generate_insert` | disabled | Optional Insert insertion |
| `model` | `<leader>cm` | Runtime model picker |
| `model_manual` | `<leader>cM` | Manual model expression |
| `clear` | `<leader>cC` | Clear working context |
| `new` | `<leader>cn` | New conversation |
| `sticky` | `<leader>cS` | Toggle automatic persistence |
| `save` | `<leader>cs` | Save conversation |
| `info` | `<leader>cx` | Runtime, budget and usage information |
| `list` | `<leader>cl` | Resume a saved conversation |

Normal replacement requires a previous valid selection in the same buffer. It never silently becomes insertion. Normal ask follows the previous selected ask only while that chain remains valid in the same buffer. Replacement, generation, or another source buffer ends the chain. `:NvClaude ask` always asks generally; `:NvClaude ask previous` explicitly requires the selected-ask target.

Mappings use native prefix resolution. `<leader>c` waits while a longer mapping is possible; use `<leader>cc` for an unambiguous action. The plugin does not change `timeoutlen` or WhichKey.

Omitted key options use defaults but preserve existing mappings. A configured string deliberately replaces that action's mapping; `false` disables one, and `keys = false` disables all. Repeated setup removes only the plugin's own mappings.

```lua
opts = {
  keys = {
    generate = "<leader>i",
    replace = "<leader>rr",
    replace_short = false,
    model = "<leader>I",
    generate_insert = false,
  },
  model = "claude-haiku-5-5", -- raw model ID, not shorthand here
  effort = "low",
  context_limit_tokens = 100000,
  thinking = false,
  -- python = "/path/to/python3",
}
```

## Commands and conversations

`:NvClaude` completes its commands. Operations are `ask [previous]`, `replace`, and `generate`. Other commands:

| Command | Meaning |
| --- | --- |
| `model` / `model manual` | Pick runtime-announced models or enter an expression |
| `model <expression>` | Configure an explicit model expression |
| `cancel` | Interrupt the current request; late output cannot edit |
| `new` | Start empty; saved prior history remains |
| `clear` | Clear active working context without deleting a saved checkpoint |
| `save` | Persist completed and future turns |
| `sticky [on\|off]` | Save current and future conversations while enabled; off does not unsave |
| `compact` | Native `/compact`, verified by its runtime completion boundary |
| `list` / `resume <id>` | Resume exact saved SDK history |
| `info` | Model, occupancy, cumulative usage, retention, versions and cache estimate |
| `system modify` / `system default` | Edit/reset the session-local system prompt |
| `watermarks allow\|remove\|replace` | Output punctuation policy |
| `login` / `update` | Official runtime authentication / explicit SDK update |

One active conversation and one turn at a time. A second submission retains its draft instead of interleaving histories. New/clear/resume cancel the old request before changing state.

Cancellation is acknowledged after the active turn drains, so the next submission cannot race the interrupted SDK turn.

Unsaved conversations expire on the next invocation after the estimated prefix-reuse interval. The default estimate is one hour for runtime-announced subscription usage, five minutes for API/cloud usage. Observed cache-creation TTL refines the estimate. Streaming consumes part of that interval. There are no heartbeat model requests. Saved conversations do not expire.

Runtime data lives in `stdpath("data")/nvim-claude`; manifests live in `stdpath("state")/nvim-claude/conversations`. SDK transcripts use the runtime's ordinary storage. Exact plugin-owned UUIDs and per-conversation locks distinguish live editors, saved conversations, and abandoned unsaved records. Cleanup deletes only unsaved records created by this plugin. It does not promise erasure of provider retention, caches, diagnostics, or unrelated Claude sessions.

## Models and budget policy

The picker uses actual runtime initialization metadata and offers only its announced effort levels. Cancel any picker step without changing configuration. Manual examples:

```text
claude-haiku-5-5[100k]:low
claude-opus-4-6[1m][500k]:high
claude-opus-4-6[1m]:high
vendor:custom-model[limit=90k]
```

Model, effort, and local budget are separate. Native documented `[1m]` variants are preserved; only the last local budget suffix is removed. Bare model IDs retain the local budget and retain effort only when runtime metadata verifies support. Unknown effort support is not guessed. Raw `opts.model`, `opts.effort`, and `opts.context_limit_tokens` bypass shorthand.

Presets, in thousands of tokens:

```text
50, 90, 100, 124, 150, 164, 200, 224, 256, 258, 274, 278,
300, 374, 378, 384, 412, 456, 500, 512, 600, 650, 700, 750,
800, 850, 900, 950, 980, model default
```

The default is Haiku 5.5, reasoning disabled, effort low, and a 100,000-token prompt ceiling. The plugin guards dispatch with a conservative UTF-8 byte upper bound on supplied system content, retained history and the next JSON payload, plus **16,384 tokens of runtime allowance**. It checks measured runtime occupancy and isolation before dispatch, reserves 4,096 output tokens against the effective physical window, and compacts before the accounted request crosses 65% of its ceiling. Native auto-compaction alone is not used as a hard wall. Runtime compaction requests must also pass the guard.

This conservative policy can reject text that a tokenizer would fit. It does not raise your limit. Large source buffers use an explicitly marked excerpt around intact targets when necessary; a mandatory instruction/target that still cannot fit is refused. General asks and whole-file selections are not silently truncated. After compaction, delivery uncertainty, or reconfiguration, the next document context is a fresh snapshot/excerpt. Confirmed exact revisions otherwise use append-only diffs or explicit unchanged markers.

The allowance and no-tools accounting were exercised against bundled CLI **2.1.306**. A different runtime version fails closed for model dispatch until its budget behavior is validated in the plugin; provisioning still installs the latest SDK as requested. `info` distinguishes conservative bounds, measured occupancy, cumulative billed usage, and cache estimates. The implementation does not claim a provider-side arbitrary-token-limit API or a guarantee against runtime behavior outside this validated configuration. See the [run record](docs/agents/benchmark-result.md) for boundary evidence and limitations.

`model_capacity_tokens` reports the model window announced in SDK results, separately from the runtime's effective auto-compaction window in `occupancy`. Cumulative token counters include native compaction and are differenced across exact-session reconnects rather than counted twice. Interrupted/error turns may lack complete runtime usage data; these are SDK usage figures, not a subscription invoice.

## Output and system prompt

Ask returns prose. Edits must return exactly one JSON object containing one string per stable target ID. The bridge rejects malformed, missing, duplicate, extra, or multiline block replacements. Only decoded replacement text is inserted, without trimming, stripping fences, or adding newlines. An empty replacement deletes; an empty insertion is a successful no-op. Clarifications never edit the source.

`watermarks` means punctuation normalization, not AI detection. Default `allow` changes nothing. `replace` maps em/en dashes to `-`, curly single/double quotes to ASCII quotes, ellipsis to `...`, and non-breaking space to ordinary space. `remove` deletes exactly those characters. Other Unicode is preserved. `punctuation_map` can explicitly extend/replace entries. Raw assistant SDK history remains unchanged; subsequent context describes the actual normalized buffer.

`system modify` opens an editable scratch buffer. `:write` applies the override to the very next turn. The bridge reconnects to the exact SDK session with prompt snapshotting disabled, retaining history while invalidating the cached prefix and document baselines. Overrides do not survive Neovim restart. `system default` restores `resources/system.txt`.

## License

[GNU GPL version 3](LICENSE). The SDK wrapper and bundled Claude Code runtime have their own licenses and terms.
