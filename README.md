# nvim-claude

A personal Neovim plugin for quick, deliberate collaboration with Claude while editing text. Select something, open a small prompt float near the cursor, say what you want, and keep writing.

This branch is the independent GPT-6 Sol medium / NeoPi benchmark candidate. It is installable without the author's Neovim configuration. The shared [specification](SPEC.md) is the behavior contract; [run results](docs/agents/benchmark-result.md) record what has actually been exercised.

## What it is

This is not a chat sidebar or an autonomous coding agent. I want four things:

1. Claude's opinion on a selection.
2. A quick general question, with follow-ups when useful.
3. A transformation of selected text, such as formatting a list or cleaning up code.
4. New text inserted at the cursor, such as a sentence continuation or generated code.

The reference is the inline workflow in the owner's personal Neovim configuration. This plugin uses its own Lua editor interface and the Python Claude Agent SDK rather than `inf` or the private config.

You choose when to invoke Claude, what it sees, and whether to continue the current conversation or start fresh. Claude gets no editing tools. Neovim applies its output to the selected range or insertion point; answers to questions stay in a float.

I have RSI, repetitive strain injury. Reducing the number of keys between a thought and an edit is the point. The plugin will live separately from my configuration so other people can use it without installing my entire setup.

## Why Claude, and why Python?

I already have Codex in my configuration, and I am developing a broader project that will eventually support multiple providers. In the meantime, I want Haiku 5.5 for fast text manipulation, reformatting, cleanup, and generation. I also find the idea of having Astra build a Claude integration funny.

The intended starting model is `claude-haiku-5-5`, with a 100,000-token prompt budget. Anthropic currently documents higher per-token pricing for Haiku 5.5 requests whose prompts exceed 100,000 tokens. Cached input counts toward that boundary too. Staying under it matters; caching alone does not avoid the higher tier. Subscription usage accounting is not necessarily identical to API pricing.[1]

The official name is **Claude Agent SDK**, singular. Anthropic provides Python and TypeScript packages. The Python SDK's source is public and MIT-licensed; that does not make the underlying Claude Code runtime open source. Both SDKs use Claude Code, whose terms and distribution are separate. I prefer Python, so that is the backend language.[2]

Lua talks to one Python process over framed JSON-RPC on stdio. The first backend action asynchronously creates a virtual environment under `stdpath('data')/nvim-claude`, installs the latest released `claude-agent-sdk` with pip, and starts the SDK's bundled Claude Code runtime. Nothing is installed into system Python. Subsequent launches reuse the environment; upgrades are explicit.

## Authentication and billing

The SDK is an official integration mechanism, but that is not a blanket guarantee about account restrictions, subscription eligibility, or billing.

Anthropic's SDK overview currently says: "Unless previously approved, Anthropic does not allow third party developers to offer claude.ai login or rate limits for their products, including agents built on the Claude Agent SDK." It directs integrations to API-key authentication. That is relevant to distributing this plugin; it does not by itself settle every case of personal local use.[3]

`:NvClaude login` opens the bundled Claude Code CLI's own login flow in a terminal buffer. The bridge reads the runtime's `auth status` but does not copy credentials. If `ANTHROPIC_API_KEY` is present, or the runtime reports API-key authentication, requests refuse paid-key billing unless `NVCLAUDE_ALLOW_API_KEY=1` is explicitly set before starting Neovim. Account eligibility is governed by Anthropic's terms.[3]

## Install

Tested locally with Neovim 0.12.4, Python 3.14.6, Claude Agent SDK 0.2.170, and bundled Claude Code 2.1.306. Python 3.10+ is required by the SDK. This candidate has not been verified on older Neovim releases. With lazy.nvim:

```lua
{
  'PsychedelicShayna/nvim-claude',
  branch = 'experimental/benchmark-sol-6-medium-neopi-20261021T164641Z-aef77442',
  main = 'nvim-claude',
  opts = {},
}
```

The command and mappings register during setup, before SDK installation or login. Provisioning starts only when a command needs the bridge. To override one mapping, use `opts = { keys = { generate = '<leader>i', model = '<leader>I' } }`. Set a mapping to `false` to disable it, or use `keys = false` to disable all plugin mappings. An existing user mapping is preserved unless its action is explicitly overridden. Set `opts.python` to a Python 3.10+ executable to choose the interpreter. Insertion from Insert mode is disabled by default; opt in with `keys.generate_insert = '<leader>ci'`.

Use `:NvClaude update` for the explicit upgrade instructions. The command reports where the venv lives; update with `~/.local/share/nvim/nvim-claude/venv/bin/python -m pip install --upgrade claude-agent-sdk`, adjusting the path if your XDG data directory differs, and restart Neovim. No separate Claude Code installation is required.

## Usage

The `<leader>c` namespace avoids replacing the owner's existing `<leader>i` mappings. `x` denotes Visual mode, `n` Normal, and `i` Insert.

| Mode | Mapping | Action |
| --- | --- | --- |
| x | `<leader>c` | Short form of selection replacement. See the timing caveat below. |
| x | `<leader>cc` | Replace the selection using the instruction entered in a cursor-local float. |
| n | `<leader>c`, `<leader>cc` | Reuse the previous valid selection in this buffer for replacement. Report when there is no valid target. |
| x | `<leader>ca` | Ask about the selection. Stream the answer into a float without changing the source buffer. |
| n | `<leader>ca` | Continue the last selected-ask target when it is still valid in this buffer and no replacement or generation has intervened. Otherwise ask generally. |
| n | `<leader>ci` | Generate at the captured cursor boundary. Insert-mode generation is opt-in through `keys.generate_insert`. |
| n | `<leader>cm` | Choose a model from the catalogue exposed by the runtime, then its supported effort and the plugin's context limit. |
| n | `<leader>cM` | Enter a model expression manually. |
| n | `<leader>cC` | `:NvClaude clear`: discard the active conversation's working context. |
| n | `<leader>cn` | `:NvClaude new`: start a separate conversation. |
| n | `<leader>cS` | `:NvClaude sticky`: toggle automatic persistence for conversations. |
| n | `<leader>cs` | `:NvClaude save`: retain the current conversation for later resumption. |
| n | `<leader>cx` | `:NvClaude info`: show context usage, model, persistence, and cache estimates in a float. |
| n | `<leader>cl` | `:NvClaude list`: pick a saved conversation to resume. |

The commands are available through `:NvClaude` with completion. `:NvClaude compact` invokes the runtime's `/compact` command; `:NvClaude cancel` interrupts the current turn. In the prompt, Ctrl-S submits in Insert or Normal mode, Enter submits in Normal mode, and Escape dismisses in Normal mode. In an answer float, `q` or Escape closes it without canceling the request.

### Mapping timing

Native Neovim mappings cannot distinguish a short mapping merely by how quickly you typed it. If `<leader>c` is both an action and a prefix for `<leader>cc`, Neovim normally waits for another key or the mapping timeout. `'timeoutlen'` controls that wait. WhichKey's display delay is a separate setting.[4]

The baseline uses native prefix behavior, with `<leader>cc` as the unambiguous action. It does not install a custom fast-tap dispatcher or change global mapping timeouts. The existing `<leader>i` interaction remains the usability reference.

Normal-mode `<leader>ca` uses the last content action and target validity, not typing speed, to distinguish a selected-ask follow-up from a general question. `:NvClaude ask` always asks generally; `:NvClaude ask previous` explicitly reuses the selected-ask target or reports that none is available. These are the specification's deterministic replacements for the original draft's timing-dependent meanings.

### Models, effort, and context limits

The intended manual syntax is:

```text
claude-haiku-5-5[100k]:low
claude-opus-4-6[1m][500k]:high
```

The first expression selects `claude-haiku-5-5`, effort `low`, and a 100k local budget. The second retains the native `[1m]` model variant and uses a separate 500k budget. Only the recognized effort suffix and local budget are removed before passing the model ID to the SDK. `[limit=90k]` always means a local budget; bare model IDs retain the current budget and supported effort. The picker uses runtime-announced models and effort levels. Unknown slugs can be entered manually, but their effort support remains unverified until the runtime accepts them.

Budget choices:

```text
50k, 90k, 100k, 124k, 150k, 164k, 200k, 224k, 256k,
258k, 274k, 278k, 300k, 374k, 378k, 384k, 412k, 456k,
500k, 512k, 600k, 650k, 700k, 750k, 800k, 850k, 900k,
950k, 980k
```

The plugin uses prior reported context occupancy, UTF-8 byte counts, and a 12k-token allowance to refuse requests that might exceed a local limit. It tries `/compact` before the context approaches the limit. The SDK does not offer an authoritative pre-dispatch count of all runtime-added input, so this is a conservative estimate, **not a verified hard 100k pricing ceiling**. Do not depend on it as a billing guarantee. `:NvClaude info` labels this uncertainty.

## Conversations and caching

Follow-ups should work. After "make this more formal," I should be able to ask "less stiff" without restating the task or selecting everything again.

Three different things are involved:

- **Conversation history** is what the SDK sends back to the model on later turns.
- **Prompt caching** lets the provider reuse computation for an unchanged prefix. A cache miss changes cost and latency, not whether history exists.
- **Persistence** determines whether the plugin retains a conversation for later resumption.

Current Claude Code documentation says main Agent SDK turns normally request a one-hour cache TTL within included subscription usage, and five minutes with usage credits, an API key, or a cloud provider. Overrides and runtime versions can change this. Direct API caching also supports both five-minute and one-hour TTLs.[5]

Unsaved conversations expire after an estimated hour when the bundled CLI reports `claude.ai` authentication, or five minutes otherwise. Saved conversations do not expire; no keep-alive requests are sent. These intervals are estimates, not a live cache measurement.

Saved conversations survive inactivity. Sticky mode makes conversations persistent automatically. A cold saved conversation can still be resumed, but rebuilding its cache may cost more.

- `:NvClaude clear` clears active working history. It does not delete Anthropic's server-side cache or erase saved conversations from the list.
- `:NvClaude new` starts another conversation, leaving a saved previous conversation available.
- `:NvClaude save` retains the current conversation.
- `:NvClaude sticky [on|off]` controls automatic persistence; with no argument, it toggles.
- `:NvClaude compact` summarizes the active context. Compaction is lossy and may itself use tokens.
- `:NvClaude info` separates current context occupancy from cumulative usage and labels estimated cache information.
- `:NvClaude list` shows saved conversations, newest first, as `YY:MM:DD:HH:MM:SS - <Initial prompt...>`.

The SDK writes session transcripts to disk by default.[6] Here, ephemeral means temporary storage, not memory-only operation. The plugin tracks its own sessions, retains their complete history on save, and removes unsaved transcripts on expiry or shutdown. Startup cleanup must not touch sessions owned by another live instance or unrelated Claude Code conversations.

## Output character handling

The original `watermarks` command name is retained, but this feature is **punctuation normalization**, not AI detection or watermark removal. An em dash is an ordinary Unicode punctuation character, not evidence that text came from a model.

- `:NvClaude watermarks allow` leaves output unchanged. This is the default.
- `:NvClaude watermarks remove` removes characters in an explicit, documented character set.
- `:NvClaude watermarks replace` substitutes those characters with configured ASCII equivalents.

This is about navigation: `f-` does not find an em dash. It is not a reason to strip arbitrary Unicode, accents, mathematical notation, or non-Latin text. The exact initial character map is specified in the spec.

Normalization applies only to displayed or inserted output. The raw assistant reply stays unchanged in conversation history. If the next request includes a buffer diff, that diff describes the actual normalized text in the buffer, so Claude can see what was really applied without rewriting earlier messages.

## Editing the system prompt

`:NvClaude system modify` opens the plugin's default prompt in an editable scratch buffer. Saving it changes the prompt for subsequent requests in this Neovim session. `:NvClaude system default` restores the built-in prompt. Overrides do not automatically persist across Neovim restarts.

Prompt changes reconnect the SDK client with the same session ID using the runtime's non-snapshotted custom prompt option. This can invalidate the cached prefix. Sticky mode changes retention, not cache validity.

The [specification](SPEC.md#model-input-and-output-contract) contains the replacement system prompt. It defines edit targets separately from supporting context, treats buffer contents as data, and distinguishes snapshots from diffs. Ask returns streaming prose. Editing returns a validated JSON result containing each target's replacement text, or a clarification that changes no buffer. Only decoded replacement text is inserted; the JSON envelope is not.

## Sources

These links support the pricing and runtime background. Executed checks for this candidate are in the run record.

1. [Haiku 5.5 context and pricing](https://code.claude.com/docs/en/model-config#haiku-5-5-context-window-and-pricing), [API prompt-caching pricing](https://platform.claude.com/docs/en/build-with-claude/prompt-caching#pricing).
2. [Python SDK repository and prerequisites](https://github.com/anthropics/claude-agent-sdk-python), [TypeScript SDK terms](https://github.com/anthropics/claude-agent-sdk-typescript#license-and-terms).
3. [Agent SDK overview and authentication restriction](https://code.claude.com/docs/en/agent-sdk/overview).
4. Neovim `:help map-ambiguous`, `:help timeoutlen`, and [`:help map-nowait`](https://neovim.io/doc/user/map.html#map-nowait).
5. [Claude Code cache lifetime](https://code.claude.com/docs/en/prompt-caching#cache-lifetime), [API prompt caching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching).
6. [SDK sessions and persistence](https://code.claude.com/docs/en/agent-sdk/sessions), [Python SDK reference](https://code.claude.com/docs/en/agent-sdk/python).

## License

See [LICENSE](LICENSE) for the GNU General Public License, version 3.
