# nvim-claude

Cursor-local Claude collaboration for Neovim. Lua captures selections, opens prompt and answer floats, and applies completed edits. A private Python environment runs the official Claude Agent SDK over framed JSON-RPC on stdio. Claude has no editing tools.

## Benchmark status

**This Astra 6 medium candidate is not a completed benchmark implementation.** Its SDK-backed editing path and editor interactions have been exercised, but the required hard 100,000-token prompt ceiling could not be established with SDK 0.2.170 / Claude Code 2.1.306.

The default 100k setting therefore **refuses model requests before dispatch**. It does not silently increase the budget or treat an estimate as enforcement. The model picker's explicit **model default** choice removes the local ceiling and enables the ordinary editing path. That choice is not a workaround satisfying the benchmark's hard-cap acceptance criterion.

The runtime counts current context, not the fully assembled next provider request. Anthropic also describes its token-count endpoint as an estimate. The runtime's auto-compaction window is not a hard input limit. See [the run record](docs/agents/benchmark-result.md) for observed results and remaining gaps, and [SPEC.md](SPEC.md) for the unchanged acceptance contract.

## Install

Tested on Linux with Neovim 0.12.4 and Python 3.14.6. The APIs require Neovim 0.11 or newer and Python 3.10 or newer; those minimum versions have not been separately exercised. This implementation uses POSIX file locks and is not a Windows implementation.

```lua
{
  "PsychedelicShayna/nvim-claude",
  branch = "experimental/benchmark-astra-6-medium-neopi-20261021T140023Z",
  main = "nvim-claude",
  opts = {},
}
```

Restart Neovim when changing candidate branches. No private configuration, `inf`, standalone Claude Code installation, or local checkout path is required.

Setup registers `:NvClaude` and mappings immediately, without authentication or a network operation. First backend use starts asynchronous provisioning: system `python3 -m venv`, then pip installs the latest released `claude-agent-sdk`. A cross-process file lock prevents concurrent installation into an incomplete environment. Only successful installs publish a runtime pointer.

Runtime environments live under `stdpath("data")/nvim-claude`. Session manifests and private working directories live under `stdpath("state")/nvim-claude`. SDK transcripts remain in the runtime's normal session store and are identified by exact UUID and private working directory. `:NvClaude update` installs a new environment; restart to use it. Old environments remain available to already-running instances and are not deleted automatically.

Options:

```lua
opts = {
  python = "python3",
  model = "claude-haiku-5-5",
  effort = "low",
  context_limit_tokens = 100000,
  keys = {
    generate = "<leader>i",
    replace = "<leader>cc",
    model = "<leader>I",
    replace_short = false,
    generate_insert = false,
  },
}
```

`data_dir` and `state_dir` optionally override the standard directories. Omitted keys retain defaults. A string explicitly replaces an action's mapping; `false` disables it. `keys = false` disables every plugin mapping. Defaults preserve existing mappings. Explicit replacements may overwrite them. Repeated setup removes only mappings still owned by the plugin, then applies the new configuration.

## Use

| Key option | Default | Modes | Action |
| --- | --- | --- | --- |
| `replace` | `<leader>cc` | Normal, Visual | Replace selection, or remembered target in this buffer |
| `replace_short` | `<leader>c` | Normal, Visual | Same replacement action |
| `ask` | `<leader>ca` | Normal, Visual | Ask generally or about a selection |
| `generate` | `<leader>ci` | Normal | Insert before the captured cursor character |
| `generate_insert` | disabled | Insert | Insert at the current insertion boundary |
| `model` | `<leader>cm` | Normal | Runtime model, effort, and budget picker |
| `model_manual` | `<leader>cM` | Normal | Manual model expression |
| `clear` | `<leader>cC` | Normal | Clear working conversation, preserving saved history |
| `new` | `<leader>cn` | Normal | Start an empty conversation |
| `sticky` | `<leader>cS` | Normal | Toggle automatic persistence |
| `save` | `<leader>cs` | Normal | Save this conversation and future turns |
| `info` | `<leader>cx` | Normal | Model, budget, usage, runtime versions, retention |
| `list` | `<leader>cl` | Normal | Select a saved conversation |

`<leader>c` is a native ambiguous mapping prefix. It waits for a possible longer mapping according to your existing `timeoutlen`; the plugin does not change global mapping timing or WhichKey.

The prompt opens near the cursor with the operation and model in its title. Ctrl-S submits in Insert or Normal mode. Enter inserts a newline in Insert mode and submits in Normal mode. Escape leaves Insert mode; a second Escape dismisses the prompt and restores focus. A second submission while a request runs retains the draft.

Ask streams into a separate float. Closing it with Normal-mode `q` or Escape hides the buffer without cancelling the request. Hidden result buffers remain accessible with Neovim's buffer commands. `:NvClaude cancel` interrupts even when the result float is hidden. Typing in the source remains possible while a request runs.

Edits apply once, after a successful SDK result and strict JSON-envelope validation. They affect captured extmarks in the original buffer, not whichever window is current. Changed/deleted/unmodifiable targets retain the proposed result without overwriting source text. One undo reverses the entire edit, including all blockwise segments. Follow-up replacements target the newly inserted text. Output whitespace and intentional empty replacements are preserved.

Normal-mode selected-ask follow-ups continue only while the last content action was that selected ask in the same buffer and the target remains valid. A replacement, generation, or different source buffer ends that chain. `:NvClaude ask` always asks generally. `:NvClaude ask previous` explicitly requests the previous selected-ask target.

## Commands

`:NvClaude` completes these subcommands:

- `ask [previous]`, `replace`, `generate`
- `cancel`, `model`, `model_manual`
- `new`, `clear`, `save`, `sticky [on|off]`, `list`, `resume <UUID>`
- `compact`, `info`
- `system modify`, `system default`
- `watermarks allow|replace|remove`
- `login`, `update`

`system modify` opens an editable scratch buffer. `:write` applies it between turns. Reconnection resumes the same SDK session with a custom prompt and `snapshot=false`, so the next request sees the override without replaying raw history. The prefix cache may be invalidated. Restarting Neovim restores the shipped prompt.

## Models and budgets

The picker reads runtime-announced models and supported efforts; it is not a hard-coded catalogue. Manual entry remains available. Cancellation at any picker stage leaves configuration unchanged. No fallback model is configured.

Examples:

| Expression | Runtime model | Local ceiling | Effort |
| --- | --- | --- | --- |
| `claude-haiku-5-5[100k]:low` | `claude-haiku-5-5` | 100,000 | low |
| `claude-opus-4-6[1m][500k]:high` | `claude-opus-4-6[1m]` | 500,000 | high |
| `claude-opus-4-6[1m]:high` | `claude-opus-4-6[1m]` | model default | high |
| `claude-haiku-5-5` | `claude-haiku-5-5` | retained | retained if supported |

`[limit=100k]` is an unambiguous local ceiling. Decimal `k` and `m` mean 1,000 and 1,000,000. Only recognized final effort suffixes are parsed; other colons remain part of the runtime ID. Recognized native `[1m]` variants remain in the model ID. Unknown nonnumeric suffixes remain untouched.

Picker budgets: 50k, 90k, 100k, 124k, 150k, 164k, 200k, 224k, 256k, 258k, 274k, 278k, 300k, 374k, 378k, 384k, 412k, 456k, 500k, 512k, 600k, 650k, 700k, 750k, 800k, 850k, 900k, 950k, 980k, and model default.

**Every explicit local ceiling currently fails closed.** With explicit model default, preflight uses the runtime context estimate, a conservative UTF-8-byte allowance for new input, and 16,384 tokens for runtime overhead. This protects against ordinary context overflow but is not advertised as a hard ceiling. It requests `/compact` before the next input would exhaust that estimate, checks the actual `compact_boundary`, and invalidates file baselines. Manual compaction uses the same runtime operation. A mandatory target that cannot fit is rejected intact. Local editing may use an explicitly marked excerpt; identified whole-document requests are not silently excerpted.

General questions attach no current file. Selected questions and edits send only their explicit buffer. Confirmed buffers use snapshots, smaller unambiguous unified diffs, or `unchanged` revisions. Reconnection, cancellation, uncertain failures, and compaction invalidate baselines.

## Authentication and isolation

`:NvClaude login` opens the SDK-bundled CLI's official `auth login` flow in a terminal buffer. The plugin does not implement OAuth or copy credentials. Existing supported runtime authentication is reused. The observed runtime reused the local Claude Max login.

This candidate removes inherited API-key, custom-endpoint, and cloud-provider selectors from its own bridge process before launching the runtime, preventing a silent change to paid API billing. It currently supports the intended personal runtime-login path, not configurable API billing. `info` reports the runtime's account type and provider without printing account identifiers.

Anthropic's [SDK overview](https://code.claude.com/docs/en/agent-sdk/overview) restricts third-party offers of claude.ai login unless approved. A working personal login probe is not a promise of subscription eligibility or permission to redistribute such access.

Isolation uses `tools=[]`, empty strict MCP configuration, `setting_sources=[]`, safe mode, disabled hooks and auto-memory, and no Chrome/IDE opt-in. Runtime context is checked for unexpected tools, memory, MCP instructions, agents, and skills; unexpected context fails closed. The successful probe also verified empty tool announcements. Python and Claude Code still access their own runtime/auth/session files; this is not an OS sandbox.

## Persistence and punctuation

Unsaved conversations expire on the next invocation after the estimated prefix-cache interval: one hour for an announced subscription, five minutes otherwise. Saved conversations do not expire. There are no heartbeat requests or background cache warming. Cache estimates do not promise remote retention or deletion.

The bridge holds an advisory lease for each active conversation. Startup cleanup removes only abandoned, unsaved plugin-owned sessions whose leases can be acquired. `new`, expiry, and clean shutdown delete unsaved SDK transcripts by exact UUID and working directory. `clear` preserves a saved checkpoint. Save and sticky preserve SDK-backed history without replay. A conversation open in another editor cannot be resumed concurrently.

`watermarks` is punctuation normalization, not watermark detection. Default `allow` changes nothing. `replace` maps em/en dashes to `-`, curly quotes to straight quotes, ellipsis to `...`, and nonbreaking space to ordinary space. `remove` deletes only those characters. Both are opt-in. Raw SDK history remains unchanged; later buffer context describes the actual normalized content.

## References and license

- [Shared specification](SPEC.md)
- [Python SDK reference](https://code.claude.com/docs/en/agent-sdk/python)
- [Token-count estimate semantics](https://platform.claude.com/docs/en/build-with-claude/token-counting)
- [Model and compaction configuration](https://code.claude.com/docs/en/model-config)

GPL-3.0, see [LICENSE](LICENSE). The SDK and its bundled runtime have their own licenses and terms.
