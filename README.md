# nvim-claude

> [!IMPORTANT]
> Round 1 metadata-only post-run correction. This candidate ran with GPT-6 Astra, `openai-codex/gpt-6-astra`, at **high** effort in NeoPi.
> Original branch: `experimental/benchmark-astra-6-neopi-20261021T135334822264899Z`.
> Original delivered commit: [`5f1242e9b8e23ef0b875444b58030f00513cb644`](https://github.com/PsychedelicShayna/nvim-claude/commit/5f1242e9b8e23ef0b875444b58030f00513cb644).
> Corrected installable branch: [`experimental/round-1-astra-6-high-neopi-20261021T135334822264899Z`](https://github.com/PsychedelicShayna/nvim-claude/tree/experimental/round-1-astra-6-high-neopi-20261021T135334822264899Z).
> The branch rename and this README-only commit correct attribution after delivery. They do not change the implementation, rerun the benchmark, or rewrite the historical run record.

Cursor-local collaboration with Claude in Neovim. Select text to replace it, generate at a captured insertion point, or ask a question in a separate float. Lua owns edits; the official Python Claude Agent SDK supplies responses. Claude has no tools.

This is the independent Astra 6 / NeoPi benchmark candidate. It is not merged into nightly or master. The shared behavior contract remains in [SPEC.md](SPEC.md); observed results and limitations are in [the run record](docs/agents/benchmark-result.md).

## Install

Requires Neovim 0.11 or newer, Python 3.10 or newer with `venv` and pip, and HTTPS access to PyPI and Anthropic. Linux and macOS are supported by the POSIX environment lock. Exercised on Neovim 0.12.4 and Python 3.14.6 on Linux. Windows is not supported.

```lua
{
  "PsychedelicShayna/nvim-claude",
  branch = "experimental/round-1-astra-6-high-neopi-20261021T135334822264899Z",
  main = "nvim-claude",
  opts = {},
}
```

Restart Neovim after switching candidates. No private editor configuration, separate Claude Code installation, Node installation, or developer checkout is needed.

Setup registers commands and mappings immediately. The first backend action asynchronously creates `stdpath('data')/nvim-claude/venv` and installs the latest released `claude-agent-sdk`, which includes Claude Code. Editors share an installation lock; a failed installation never gets a ready marker. `:NvClaude setup` provisions explicitly. `:NvClaude update` installs the latest SDK after restarting Neovim, before opening a bridge. Installation is not repeated on each launch.

## Authentication and billing

`:NvClaude login` opens the bundled CLI's official `auth login` flow in a terminal buffer. The runtime discovers its existing credentials normally. The plugin does not read or copy refresh tokens. Missing credentials do not prevent loading the plugin or opening prompts.

The default `auth = "runtime"` refuses an inherited `ANTHROPIC_API_KEY`, since noninteractive Claude Code would otherwise use paid API billing instead of subscription login. For explicitly authorized API usage:

```lua
opts = { auth = "api" } -- requires ANTHROPIC_API_KEY in Neovim's environment
```

This mode refuses a missing key rather than falling back to a subscription. Custom gateways, bearer-token overrides, Bedrock, Vertex, and Foundry are not supported by this candidate's first-party request gate. No credential-dependent retry changes the billing mode or model.

Anthropic's [SDK overview](https://code.claude.com/docs/en/agent-sdk/overview) restricts third-party products offering claude.ai login without approval. Official SDK availability does not guarantee subscription eligibility or account-policy approval. The personal existing-login flow worked in this run; distribution users should follow Anthropic's current authentication terms.

## Editing

The prompt opens near the cursor with the operation and model in its title. It starts in Insert mode, grows for multiline instructions, and highlights the captured target.

- Ctrl-S submits in Insert or Normal mode.
- Enter adds a newline in Insert mode and submits in Normal mode.
- Escape leaves Insert mode. Escape in Normal mode dismisses the prompt and restores the origin window.
- Continue editing while Claude works. The source edit happens only after a successful final response and complete validation.
- `:NvClaude cancel` interrupts a turn. Canceled or superseded results never edit the source.

Answers and previews use ordinary Neovim buffers. Enter the float with normal window navigation. Normal-mode `q` or Escape hides it and restores the origin window. Hiding a float does not cancel the request. `:NvClaude result` reopens the last result.

Targets use extmarks and captured text, not the current cursor when a response arrives. Unrelated edits can move a target. Changed, deleted, or nonmodifiable targets retain their result in the float instead of overwriting user work. A successful edit is one undo step. A replacement follow-up targets the new text. Undoing that replacement invalidates the remembered target.

Characterwise, reversed, linewise, and blockwise selections use Neovim's native region geometry. Blockwise responses have one replacement per row. Partial tabs preserve unselected cells as spaces. Multiline block replacements are rejected. Text is not trimmed; whitespace and empty replacements are meaningful.

## Mappings

Each `keys` value can be a replacement string or `false`. Omitted entries use the defaults. `keys = false` disables all plugin mappings. Defaults preserve existing user mappings; an explicitly supplied string authorizes replacing that mapping. Repeated setup removes only mappings still owned by the plugin.

| Option | Default | Modes | Action |
| --- | --- | --- | --- |
| `replace` | `<leader>cc` | Normal, Visual | Replace current or remembered selection |
| `replace_short` | `<leader>c` | Normal, Visual | Same replacement action |
| `ask` | `<leader>ca` | Normal, Visual | General or selected question |
| `generate` | `<leader>ci` | Normal | Insert before the cursor character |
| `generate_insert` | disabled | Insert | Insert at the insertion boundary |
| `model` | `<leader>cm` | Normal | Runtime model, effort, budget picker |
| `model_manual` | `<leader>cM` | Normal | Enter a model expression |
| `clear` | `<leader>cC` | Normal | Clear working context, retain saved history |
| `new` | `<leader>cn` | Normal | Start an empty conversation |
| `sticky` | `<leader>cS` | Normal | Toggle automatic persistence |
| `save` | `<leader>cs` | Normal | Retain this conversation and future turns |
| `info` | `<leader>cx` | Normal | Model, runtime, budget, cache and usage details |
| `list` | `<leader>cl` | Normal | Resume a saved conversation |

Native mapping resolution applies: `<leader>c` waits while a longer mapping remains possible. The plugin changes neither `timeoutlen` nor WhichKey settings. Use `<leader>cc` for an unambiguous replacement.

Normal replacement requires a valid remembered target in the same buffer. It never silently becomes generation. Normal mapped ask follows the previous selected ask only while its target remains valid in that buffer and no other content operation has intervened. Menus do not end the chain. `:NvClaude ask` always asks generally; `:NvClaude ask previous` explicitly requires the selected-ask target.

To restore the familiar `i` / `I` gestures without changing the common command namespace:

```lua
opts = {
  keys = {
    generate = "<leader>i",  -- Normal mode
    replace = false,
    model = "<leader>I",
    generate_insert = false,
    replace_short = false,
  },
}
```

Then add the Visual replacement mapping after setup. This gives Normal generation and Visual replacement without assigning two actions to the same key in the same mode:

```lua
vim.keymap.set("x", "<leader>i", function()
  require("nvim-claude").invoke("replace", true)
end)
```

## Commands and conversations

`:NvClaude` completes subcommands. Alongside `ask`, `replace`, `generate`, `model`, `login`, `setup`, `update`, `cancel`, and `result`, it provides:

| Command | Behavior |
| --- | --- |
| `new` | Detach; delete unsaved owned transcripts, retain saved conversations |
| `clear` | Discard working context and baselines; retain the saved conversation checkpoint |
| `save` | Persist the active SDK session and all subsequent completed turns |
| `sticky [on\|off]` | Save the current conversation when enabled; persist future conversations automatically |
| `compact` | Run the actual runtime `/compact` command and require its compaction boundary |
| `list` | Newest-first saved picker, timestamp and stable ID included |
| `resume <UUID>` | Resume one saved conversation, refusing concurrent ownership |
| `info` | Report model, local limit, occupancy, cumulative usage, retention, versions and estimated cache state |
| `system modify` | Open an editable scratch prompt; `:write` updates the next turn |
| `system default` | Restore the shipped prompt |
| `watermarks allow\|remove\|replace` | Select presentation-only punctuation handling |

One active turn is allowed. A second prompt submission stays open with its draft intact. Conversation changes invalidate the generation epoch and cancel the active turn before the bridge changes state.

Saved SDK transcripts resume across editor restarts. Manifests live under `stdpath('state')/nvim-claude/sessions`. Per-conversation OS locks establish live ownership. Unsaved sessions are deleted on new, expiry, and orderly shutdown. Startup removes abandoned unsaved sessions only after acquiring their ownership lock. Cleanup calls the SDK with exact recorded session IDs and project directories; unrelated Claude sessions are never swept. Runtime diagnostics and provider retention are distinct from transcript cleanup.

Ephemeral expiry is evaluated at the next invocation, never halfway through a response. The estimated interval is one hour for runtime-announced subscription authentication and five minutes otherwise, adjusted for explicit runtime TTL overrides. Saved conversations do not expire. No background requests keep caches warm.

System overrides are local to the current Neovim process. Reconnecting the same SDK session with `snapshot = false` applies changes on the next request while retaining history. Prefix reuse may be lost. Prompt changes never rewrite old assistant messages.

## Models and budgets

Default configuration:

```lua
opts = {
  python = "python3",
  model = "claude-haiku-5-5",
  effort = "low",
  context_limit_tokens = 100000,
  auth = "runtime",
}
```

Haiku 5.5 reasoning is disabled for quick edits. Other models use reasoning-off only when runtime metadata announces support; otherwise their runtime default applies. The selected effort is sent explicitly. The picker uses only runtime-announced models and effort levels. Canceling any picker stage leaves the configuration unchanged. Unknown manual models remain usable with `effort = false`, which omits an unverified effort value. `context_limit_tokens = false` chooses the model default.

Manual expressions separate the runtime selector from the local budget:

```text
claude-haiku-5-5[100k]:low
claude-opus-4-6[1m][500k]:high
claude-haiku-5-5[limit=90k]:low
```

A recognized native `[1m]` selector remains in the runtime model ID. Arbitrary colons remain part of an ID unless followed by a recognized effort token. A bare model retains the budget; it retains effort only where runtime metadata confirms support. Separate setup fields bypass expression parsing.

Available budgets, in thousands of tokens: 50, 90, 100, 124, 150, 164, 200, 224, 256, 258, 274, 278, 300, 374, 378, 384, 412, 456, 500, 512, 600, 650, 700, 750, 800, 850, 900, 950, 980, plus model default. A local limit never enlarges a model's physical window.

### Admission rather than a compaction promise

The SDK has no hard prompt-token option. This candidate uses two stages:

1. Before a turn, a conservative planning bound accounts for the system prompt, retained history, current instruction, target, and snapshot/diff. It reserves room for output and early compaction. A full snapshot that cannot fit may become a labeled excerpt around the intact target, with omitted rows identified. A mandatory target that cannot fit is refused.
2. A private loopback gate receives the SDK's fully assembled Anthropic request. **Before forwarding**, it checks the complete serialized UTF-8 byte count plus a 16,384-token provider-framing allowance against the effective limit. Byte-fallback tokenization cannot require more tokens than the serialized bytes representing its text. JSON syntax and the additional allowance deliberately overcount. This is conservative admission, not an exact tokenizer: ASCII text commonly reaches this byte bound well before its actual token count reaches the selected number.

The second stage sees runtime-added content, cached history, and compaction prompts. Tool-bearing and non-text requests without a safe byte bound are rejected. Thus an inaccurate planning estimate cannot cause an oversized text request to bypass the gate. Model output reserves also constrain the physical window. `info` separates the last complete-wire bound from runtime-estimated occupancy and cumulative billed usage. The allowance is a stated assumption about provider-private framing, not a claim to inspect Anthropic's private processing.

The gate listens only on `127.0.0.1` at a random port with a 256-bit random path, rejects browser Origin headers, forwards only Messages/token-count paths to `https://api.anthropic.com`, and records neither headers nor bodies. Credentials remain in process memory. The editor-to-Python protocol is Content-Length framed JSON-RPC over stdio; no editor API is exposed over HTTP.

## Context and output

General ask attaches no document. Selected asks and editing operations send serialized JSON with exact current targets and explicit snapshot, diff, unchanged, or excerpt context. Baselines advance only after successful runtime completion. Compaction, uncertain delivery, and resumption invalidate baselines. A summary is never treated as an exact file revision.

Edit output must be one JSON object with exactly one string replacement per target, or a `needs_input` clarification. Malformed output, duplicate IDs, missing targets, and multiline block replacements stay in the result float. No automatic retry spends more usage. Raw assistant text stays unchanged in SDK history.

`watermarks` means punctuation normalization, not AI detection. Default `allow` preserves everything. `replace` maps em/en dashes to `-`, curly single quotes to `'`, curly double quotes to `"`, ellipsis to `...`, and nonbreaking space to an ordinary space. `remove` deletes precisely those characters and can join words or alter code. Other Unicode is unchanged. `opts.punctuation` can supply a replacement map. Only displayed or inserted text is normalized; later context reflects the actual buffer.

## License

[GNU GPL v3](LICENSE). The [Python SDK](https://github.com/anthropics/claude-agent-sdk-python) is MIT-licensed; its bundled Claude Code runtime has separate terms.
