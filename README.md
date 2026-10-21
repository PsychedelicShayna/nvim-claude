# nvim-claude

A cursor-local Claude editing companion for Neovim. Select text, open a prompt float, and submit an instruction. Ask streams an answer without editing the source. Replace changes only the captured selection. Generate inserts before the captured cursor character.

This is the **Sol 6.1 medium / NeoPi benchmark candidate**, not the selected stable implementation. Its draft comparison PR stays unmerged until the owner chooses a candidate. [SPEC.md](SPEC.md) is the shared behavior contract; [the run record](docs/agents/benchmark-result.md) records exercised behavior and limitations.

## Install

Verified with Neovim 0.12.4, Python 3.14.6, Claude Agent SDK 0.2.170 and bundled Claude Code 2.1.306 on Linux. The client uses Neovim 0.10+ APIs and requires Python 3.10+, pip/venv support, and `flock`. Older Neovim/Python versions have not been exercised. There is no dependency on a private configuration, `inf`, a developer checkout, or a separately installed Claude Code.

```lua
{
  "PsychedelicShayna/nvim-claude",
  branch = "experimental/benchmark-sol-6-1-medium-neopi-20261021-7c92a",
  main = "nvim-claude",
  opts = {},
}
```

Restart Neovim after switching candidate branches. Setup registers commands and mappings immediately, without authentication or a network request. First backend use asynchronously creates a venv under `stdpath('data')/nvim-claude/runtime` and installs the latest released `claude-agent-sdk`. The SDK includes the CLI. Installation takes an OS lock shared by editor instances. A failed installation never gets a ready marker. Later invocations reuse the environment; `:NvClaude update` explicitly upgrades it.

Optional settings:

```lua
opts = {
  python = "python3",
  model = "claude-haiku-5-5",
  effort = "low",
  context_limit_tokens = 100000,
  keys = {
    replace_short = false,
    generate = "<leader>i",
    model = "<leader>I",
    generate_insert = false,
  },
}
```

Omitted key options use the defaults below. A string explicitly replaces a mapping, `false` disables that action, and `keys = false` disables all plugin mappings. Defaults preserve existing user mappings. Repeated setup removes only the plugin's own previous mappings. Insert-mode generation is opt-in. Native mapping resolution controls prefix delays; the plugin does not change `timeoutlen` or WhichKey.

## Interaction

The prompt appears near the cursor and accepts multiline input. Ctrl-S submits from Insert or Normal mode. Enter submits in Normal mode and inserts a newline in Insert mode. Escape leaves Insert mode; a second Escape dismisses the prompt. The source target is highlighted and belongs to its captured buffer even if focus changes.

Ask output streams into a float. Editing output is a preview until the complete SDK result and edit envelope validate. The plugin never trims text or strips code fences. Empty replacement text deletes the selection. A target changed during a request is not overwritten; the result remains available with an explanation. Unrelated edits move targets through extmarks. Successful output is one undo step. Undoing or changing a remembered target invalidates it rather than guessing a replacement range.

In answer floats, `q` or Escape closes the window and restores the origin window. Hiding an answer does not cancel its request. Use `:NvClaude cancel` to interrupt. A second submission during a turn retains its prompt draft instead of interleaving conversations.

| Option | Default | Modes | Action |
| --- | --- | --- | --- |
| `replace` | `<leader>cc` | Normal, Visual | Replace selection or previous valid replacement target |
| `replace_short` | `<leader>c` | Normal, Visual | Same action, native prefix delay |
| `ask` | `<leader>ca` | Normal, Visual | Ask generally or about selection; Normal follows a valid selected-ask chain |
| `generate` | `<leader>ci` | Normal | Insert at captured cursor boundary |
| `generate_insert` | disabled | Insert | Opt-in insertion mapping |
| `model` | `<leader>cm` | Normal | Runtime model, supported effort, budget picker |
| `model_manual` | `<leader>cM` | Normal | Manual model expression |
| `clear` | `<leader>cC` | Normal | Discard working context, retain saved checkpoint |
| `new` | `<leader>cn` | Normal | Start a new conversation |
| `sticky` | `<leader>cS` | Normal | Toggle automatic persistence |
| `save` | `<leader>cs` | Normal | Save current conversation and future turns |
| `info` | `<leader>cx` | Normal | Runtime, context, billing, retention and cache information |
| `list` | `<leader>cl` | Normal | Resume a saved conversation |

`:NvClaude` completes command names. Commands are `ask [previous]`, `replace`, `generate`, `model [manual|expression]`, `clear`, `new`, `save`, `sticky [on|off]`, `compact`, `info`, `list`, `resume <id>`, `cancel`, `watermarks allow|remove|replace`, `system modify|default`, `login`, and `update`. A range on `ask` or `replace` uses the visual selection. Plain `:NvClaude ask` never attaches a file implicitly. `ask previous` requires a valid selected-ask target. Replace/generate, another source buffer, or target invalidation ends that chain.

Selections support characterwise, linewise, reverse and blockwise ranges. Blocks are independent row segments, applied bottom-up in one undo block. Partial tab cells become spaces so cells outside the selection survive. A block replacement containing a newline is rejected. The model gets no file-editing tools; Lua applies only validated target IDs.

## Authentication and billing

`:NvClaude login` opens the SDK's bundled CLI `auth login` flow in a terminal. Existing supported Claude Code credentials are discovered by the runtime without copying tokens into plugin storage. Setup and the prompt work before login. Backend authentication errors leave source text unchanged. `info` reports subscription/provider metadata when available, without displaying tokens.

The plugin refuses requests when `ANTHROPIC_API_KEY` is inherited, because non-interactive Claude Code would silently prioritize API billing over a subscription. Unset it to use runtime login. It does not implement OAuth or copy credentials. Custom auth tokens and provider routing remain runtime configuration; the plugin cannot guarantee their billing mode.

The Agent SDK's [distribution/authentication restriction](https://code.claude.com/docs/en/agent-sdk/overview) still applies. Bundling Claude Code does not grant subscription eligibility or exempt a product from Anthropic's terms. The Python SDK and bundled runtime have separate licensing/terms.

## Models and budgets

The picker uses runtime-announced models and their supported efforts. No static catalogue is presented as discovery. Manual entry remains available:

```text
claude-haiku-5-5[100k]:low
claude-opus-4-6[1m][500k]:high
claude-haiku-5-5[limit=90k]:medium
```

The final recognized effort suffix is separate from the runtime model. Decimal `k` and `m` mean 1,000 and 1,000,000. Recognized native `[1m]` selectors are retained; a second numeric group or `[limit=...]` sets the local budget. Raw `model`, `effort`, and `context_limit_tokens` fields bypass shorthand parsing. Manual unknown model IDs are never silently replaced by another model; unknown effort support is not advertised as verified.

Presets are 50k, 90k, 100k, 124k, 150k, 164k, 200k, 224k, 256k, 258k, 274k, 278k, 300k, 374k, 378k, 384k, 412k, 456k, 500k, 512k, 600k, 650k, 700k, 750k, 800k, 850k, 900k, 950k and 980k, plus model default. A local budget cannot enlarge physical context.

The bridge uses a conservative UTF-8 byte bound for supplied text/history, reported output tokens, 256 framing tokens per historical entry, and a 16,384-token runtime allowance. It also reserves 8,192 output tokens against the physical window. It refuses oversize mandatory targets/instructions before dispatch. Local tasks can use an explicitly marked excerpt around an intact target; whole-file tasks are not silently truncated. Long histories trigger actual runtime `/compact` before the next request, and compaction itself must fit. A compaction boundary invalidates all buffer baselines.

**This is not a provider-verified hard pricing ceiling.** The SDK exposes context accounting, but not an authoritative pre-dispatch count of the final provider request or a provider-enforced arbitrary input ceiling. `info` labels that limitation. The 100k guard has an explicit runtime-overhead assumption; do not rely on it as a billing guarantee. Ordinary Haiku edits and local refusal boundaries are exercised. A strict provider-side 100k guarantee remains an upstream limitation against the shared spec, not a passing claim. The SDK is asked to disable thinking; current runtime metadata says Haiku 5.5 does not support thinking-off, so that setting cannot be promised effective for every turn.

## Context and retention

General ask sends only the instruction. Selected asks and edits send a serialized JSON envelope, exact target text, boundary text and explicit buffer context. The first revision is a snapshot. Follow-ups use `unchanged`, a zero-based line-splice diff against the confirmed baseline, or a smaller fresh snapshot. Failed/uncertain delivery, reconnects, prompt changes and compaction invalidate baselines. Presentation normalization and user undo appear in later actual-buffer context, not rewritten assistant history.

Unsaved conversations expire on the next invocation after the estimated reuse interval, never mid-turn. The estimate is one hour for announced subscription credentials and five minutes otherwise. Account transitions, usage credits and runtime overrides may change provider TTL; this is not a cache-hit assertion. No heartbeat or warming request is sent.

Saved conversations survive expiry and Neovim restarts. Sticky-on saves the current conversation and future conversations; sticky-off does not unsave existing ones. Clear/new detach from saved checkpoints rather than deleting them. Listing shows timestamp, first instruction and stable ID. SDK-backed transcripts are retained exactly for resume. Plugin manifests live under `stdpath('state')/nvim-claude/conversations`; OS leases prevent concurrent resumption and distinguish abandoned unsaved records from another live editor. Cleanup deletes only SDK session IDs recorded in those manifests, never unrelated Claude sessions. SDK/provider diagnostic retention is not forensic erasure.

## Punctuation and system prompt

`watermarks` is punctuation normalization, not AI detection. Default `allow` leaves output unchanged. `replace` maps em/en dash to `-`, curly single quotes to `'`, curly double quotes to `"`, ellipsis to `...`, and NBSP to ordinary space. `remove` deletes exactly those characters and can join words or damage code. Neither mode changes accents, mathematics, non-Latin text, emoji, or raw assistant history.

`system modify` opens the current static prompt in a scratch buffer. `:write` changes the session-local override between turns. The bridge reconnects to the exact SDK session with custom prompt snapshotting disabled, preserving history while using the override on the next request. That can invalidate cached prefixes. `system default` restores the shipped prompt; restarting Neovim clears the override.

## Implementation

Lua owns targets, undo, floats and mappings. One lazy Python process owns the SDK conversation and exchanges Content-Length-framed JSON-RPC over stdio. There is no listening server or browser endpoint. The runtime receives `tools=[]`, empty strict MCP configuration, no settings sources, empty agents/plugins, disabled hooks/memory/IDE attachments, safe mode, and per-message verbatim user input. It checks reported context for unexpected tools, memory or agents. Runtime initialization has been observed announcing no tools, MCP servers, agents or skills. Managed policy still belongs to the installed runtime.

See [CHANGELOG.md](CHANGELOG.md), [SPEC.md](SPEC.md), and the [benchmark record](docs/agents/benchmark-result.md). License: [GPL-3.0](LICENSE).
