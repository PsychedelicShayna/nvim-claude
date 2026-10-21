# nvim-claude

Cursor-local questions, replacements and generation in Neovim, backed by the Python Claude Agent SDK. Lua captures the target and applies a completed edit. Claude has no model-accessible tools and does not read your project.

This is the **Astra 6 low / NeoPi benchmark candidate**. It is not a passing implementation of every requirement in [SPEC.md](SPEC.md). The strict prompt-budget requirement remains unresolved: SDK 0.2.170 and CLI 2.1.306 expose current usage, but no authoritative bound on runtime-added input for the next request. The default 100k strict mode therefore refuses model dispatch. It does not silently substitute a soft limit.

Real editing, streaming, compaction and resumption have been exercised with the explicitly selected `budget_mode = "conservative"` setting below. That mode is an estimate, not 100k price-tier protection. See [the run record](docs/agents/benchmark-result.md) for verification and remaining limitations. Candidates stay unmerged until owner selection.

## Install

Tested on Linux with Neovim 0.12.4 and Python 3.14. Versions below Neovim 0.12 are not supported by this candidate. The Python code requires 3.10 or newer, with `venv` and `ensurepip`; older Python versions have not been exercised. Provisioning uses POSIX file locks, so native Windows is not supported.

```lua
{
  "PsychedelicShayna/nvim-claude",
  branch = "experimental/benchmark-astra-6-low-neopi-20261021-a7d3",
  main = "nvim-claude",
  opts = {},
}
```

Commands and mappings load without authentication or network access. First backend use asynchronously creates `stdpath("data")/nvim-claude/venv`, installs the latest released `claude-agent-sdk`, and starts its bundled CLI. Nothing is installed into system Python or the plugin checkout. An installation lock prevents two editors from using a half-installed environment. Later launches reuse it. `:NvClaude update` explicitly upgrades it.

To exercise model-backed behavior while accepting the unresolved hard-ceiling limitation, deliberately configure:

```lua
opts = {
  budget_mode = "conservative",
  model_config = {
    model = "claude-haiku-5-5",
    effort = "low",
    context_limit_tokens = 100000,
  },
}
```

The conservative check counts supplied UTF-8 bytes, effective history bytes, a 16,384-token runtime allowance and 256 tokens per turn. Text byte counts overestimate text tokens, but the runtime allowance is not an authoritative bound. It compacts proactively at 70% of that estimate, refuses oversized mandatory targets, and uses explicitly marked excerpts when a full buffer does not fit. Whole-buffer targets are never silently excerpted. A compaction trigger is not a hard ceiling. `info` reports `verified_hard_ceiling = false`.

Other setup fields are `python`, `data_dir`, `state_dir` and `billing`. Defaults use `python3` and Neovim's standard data/state directories. No private configuration, `inf`, separate Claude installation or local development path is required. Restart Neovim when switching candidate branches.

## Interaction

Select text and press `<leader>cc`. A prompt opens near the cursor, with the operation and model in its title. Enter inserts a newline in Insert mode. Ctrl-S submits from either Insert or Normal mode; Enter submits in Normal mode. Escape leaves Insert mode, then a second Escape closes the prompt and restores the source window.

Keep typing while a request runs. Ask output streams into a separate float. An edit is applied once, only after a successful SDK result and a valid target-addressed JSON response. One undo reverses the edit without undoing unrelated typing. If the source or target changed, the output remains in the result float rather than overwriting it. An empty replacement deletes the target; empty generation is a reported no-op. Whitespace and literal fences are not trimmed.

Targets use extmarks, UTF-8 byte boundaries and change invalidation. Block selections keep one ID per row, preserve unselected cells when a tab or wide character is partially selected, and reject multiline replacements. Normal generation inserts before the cursor character. Insert generation captures the actual insertion boundary.

Normal-mode `q` or Escape hides a result float and restores its origin window. Hiding it does not cancel the request. `:NvClaude result` reopens the last result; `:NvClaude cancel` interrupts the request even when its float is hidden. Request epochs prevent canceled or detached results from editing buffers. A second submission while the conversation is busy leaves its prompt draft open.

### Mappings

| Option | Default | Modes | Action |
| --- | --- | --- | --- |
| `replace` | `<leader>cc` | Normal, Visual | Replace selection, or previous valid target in this buffer |
| `replace_short` | `<leader>c` | Normal, Visual | Same action using native prefix timing |
| `ask` | `<leader>ca` | Normal, Visual | Ask generally or about selection; continue a valid selected-ask chain |
| `generate` | `<leader>ci` | Normal | Insert at captured cursor boundary |
| `generate_insert` | disabled | Insert | Opt-in insertion mapping |
| `model` | `<leader>cm` | Normal | Runtime model picker, effort, then budget |
| `model_manual` | `<leader>cM` | Normal | Enter a model expression |
| `clear` | `<leader>cC` | Normal | Discard working context, retain saved history |
| `new` | `<leader>cn` | Normal | Start a separate conversation |
| `sticky` | `<leader>cS` | Normal | Toggle automatic saving |
| `save` | `<leader>cs` | Normal | Save the active conversation and future completed turns |
| `info` | `<leader>cx` | Normal | Usage, model, retention, versions and cache estimate |
| `list` | `<leader>cl` | Normal | Pick a saved conversation to resume |

An omitted key uses its default, a string overrides it, and `false` disables it. `keys = false` disables all plugin mappings. Defaults preserve existing user mappings. An explicitly configured string replaces an existing mapping. Repeated setup removes only mappings still owned by this plugin, then applies the new configuration.

```lua
keys = {
  generate = "<leader>i",
  replace = "<leader>cc",
  model = "<leader>I",
  replace_short = false,
  generate_insert = "<C-g>i",
}
```

Native `<leader>c` waits when a longer mapping is possible. The plugin does not change `timeoutlen` or WhichKey. Normal ask follows the last selected-ask target only while that chain remains valid. Replacement, generation, a different content buffer or an invalid target ends it. Settings menus do not. `:NvClaude ask` always asks generally; `:NvClaude ask previous` requires an existing selected-ask target.

## Commands and conversations

`:NvClaude` completes command names. It supports `ask [previous]`, `replace`, `generate`, `cancel`, `result`, `new`, `clear`, `save`, `sticky [on|off]`, `compact`, `list`, `info`, `model [manual|expression]`, `system modify`, `system default`, `watermarks allow|replace|remove`, `login` and `update`.

General ask adds no current file implicitly. Selection asks and editing send a JSON envelope containing the current target and explicit buffer context. The first accepted context is a snapshot, later context is an append-only diff or an `unchanged` marker. After uncertain delivery, resumption or compaction, the plugin sends fresh context. The current target and nearby boundary text are always supplied independently.

There is one active logical conversation per editor. Its SDK process stays alive between turns. Model or prompt changes reconnect to the same SDK session with a fresh prompt prefix; this can invalidate the provider cache, but does not replay or rewrite raw assistant history. `system modify` opens a writable scratch buffer; `:write` applies the override between turns. `system default` restores the static resource. Overrides disappear when Neovim exits.

`save` retains the SDK transcript and plugin manifest. `sticky on` also saves future conversations; turning it off does not unsave existing ones. `clear` and `new` detach from the current conversation and preserve any saved record. `list` shows saved records newest-first, with timestamp, initial prompt and stable ID. A file lock prevents concurrent writers to a saved conversation.

Unsaved conversations expire only before the next invocation, never during a turn. The timer uses the last API cache-creation TTL when reported, otherwise a conservative five-minute estimate. It is not proof that the provider still has a cached prefix. Saved conversations do not expire. There are no background cache-warming requests.

Manifests under `stdpath("state")/nvim-claude/conversations` identify exact SDK session IDs and their plugin-owned working directories. On expiry, replacement or clean exit, the plugin calls the SDK's session deletion API for those IDs only. Startup removes abandoned unsaved records only after acquiring their ownership lock. Saved sessions survive restart. This is local transcript retention, not a promise of forensic erasure or deletion of provider records.

`compact` invokes the runtime's real `/compact` command and requires its `compact_boundary` event. The CLI's `--disable-slash-commands` also disables `/compact`, so compaction briefly reconnects the same session with that flag removed, still with `tools=[]`, no MCP and no subagents. It restores the no-skills execution configuration before the next content request. Compaction preserves a summary, not verbatim context, and invalidates buffer baselines.

## Models and punctuation

The picker displays models announced by the installed runtime. It offers only the effort levels that model announces. Canceling any picker step leaves all settings unchanged. Manual IDs remain available if discovery fails or omits a model. Unknown manual effort support is not certified by the plugin; runtime rejection is displayed without selecting a fallback.

```text
claude-haiku-5-5[100k]:low
claude-opus-4-6[1m][500k]:high
claude-opus-4-6[1m]:high
provider:custom-id[limit=90k]:medium
```

The final recognized effort suffix is separate from the runtime ID. Decimal `k` and `m` mean 1,000 and 1,000,000. Recognized native `[1m]` selectors stay on the model ID; a second numeric bracket is the local budget. A lone recognized native selector chooses model-default budget. Bare IDs retain the configured budget. `[limit=100k]` is always local. Raw `model_config` fields bypass shorthand; `effort = false` omits effort and `context_limit_tokens = vim.NIL` selects model default. No local budget enlarges a model's physical context window.

Budget presets are model default and: 50k, 90k, 100k, 124k, 150k, 164k, 200k, 224k, 256k, 258k, 274k, 278k, 300k, 374k, 378k, 384k, 412k, 456k, 500k, 512k, 600k, 650k, 700k, 750k, 800k, 850k, 900k, 950k and 980k.

`watermarks` means punctuation normalization, not AI detection. Default `allow` preserves output. `replace` maps em/en dashes to `-`, curly single/double quotes to straight quotes, ellipsis to `...`, and nonbreaking space to a space. `remove` deletes exactly those characters. Other Unicode, including zero-width joiners, passes through. The policy affects presentation and insertion only; SDK history keeps the original response.

## Authentication and isolation

`:NvClaude login` opens a terminal running the bundled CLI's official `auth login` flow. The bridge reuses supported runtime credential discovery; it does not copy credentials or implement OAuth. The exercised account used existing Claude Max credentials. Subscription eligibility for a distributed integration is not guaranteed. Anthropic's [SDK overview](https://code.claude.com/docs/en/agent-sdk/overview) says third-party developers need approval to offer claude.ai login or rate limits in their products.

Default `billing = "subscription"` refuses inherited API credentials instead of silently using paid API billing. Set `billing = "environment"` only when you intend to use your environment's credentials. `info` reports the selected mode and runtime-announced subscription type. The plugin does not store credentials in its venv or manifests.

The SDK options use `tools=[]`, empty strict MCP configuration, empty settings sources, no skills/plugins/subagents, safe mode, no IDE connection, no automatic memory and no file-mention expansion. Normal content turns additionally disable slash commands. Runtime tool, skill, agent and memory metadata are checked; unexpected capabilities fail the request. Managed policies and runtime telemetry remain upstream behavior, not an OS sandbox. Python and the CLI still need ordinary filesystem access for their own runtime and transcripts.

## Source and license

The original product draft and comparison baseline remain in Git at `4c85985bf31be8a0ca03fe0cdc345708479d4f4c`. [SPEC.md](SPEC.md) remains the acceptance contract, including the unresolved hard-budget criterion.

References: [Python SDK](https://github.com/anthropics/claude-agent-sdk-python), [SDK sessions](https://code.claude.com/docs/en/agent-sdk/sessions), [model configuration](https://code.claude.com/docs/en/model-config), [runtime environment](https://code.claude.com/docs/en/env-vars), [prompt caching](https://code.claude.com/docs/en/prompt-caching), [Neovim mapping resolution](https://neovim.io/doc/user/map.html#map-ambiguous).

GPL-3.0, see [LICENSE](LICENSE). The Python SDK and bundled Claude Code runtime have their own licenses and terms.
