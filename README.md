# nvim-claude

A personal Neovim plugin for quick, deliberate collaboration with Claude while editing text. Select something, open a small prompt float near the cursor, say what you want, and keep writing.

This branch is the Sol high NeoPi benchmark candidate. Install this exact branch to compare it with the other independent runs; the shared behavior contract remains in [SPEC.md](SPEC.md). The candidate is not merged into `benchmark` or `nightly`.

## What it is

This is not a chat sidebar or an autonomous coding agent. I want four things:

1. Claude's opinion on a selection.
2. A quick general question, with follow-ups when useful.
3. A transformation of selected text, such as formatting a list or cleaning up code.
4. New text inserted at the cursor, such as a sentence continuation or generated code.

The reference is the inline workflow in my personal Neovim configuration. This plugin keeps its small, cursor-local interaction and replaces the `inf` backend with the Python Claude Agent SDK. The private configuration is not an installation dependency.

You choose when to invoke Claude, what it sees, and whether to continue the current conversation or start fresh. Claude gets no editing tools. Neovim applies its output to the selected range or insertion point; answers to questions stay in a float.

I have RSI, repetitive strain injury. Reducing the number of keys between a thought and an edit is the point. The plugin will live separately from my configuration so other people can use it without installing my entire setup.

## Why Claude, and why Python?

I already have Codex in my configuration, and I am developing a broader project that will eventually support multiple providers. In the meantime, I want Haiku 5.5 for fast text manipulation, reformatting, cleanup, and generation. I also find the idea of having Astra build a Claude integration funny.

The intended starting model is `claude-haiku-5-5`, with a 100,000-token prompt budget. Anthropic currently documents higher per-token pricing for Haiku 5.5 requests whose prompts exceed 100,000 tokens. Cached input counts toward that boundary too. Staying under it matters; caching alone does not avoid the higher tier. Subscription usage accounting is not necessarily identical to API pricing.[1]

The official name is **Claude Agent SDK**, singular. Anthropic provides Python and TypeScript packages. The Python SDK's source is public and MIT-licensed; that does not make the underlying Claude Code runtime open source. Both SDKs use Claude Code, whose terms and distribution are separate. I prefer Python, so that is the backend language.[2]

Lua talks to a local Python bridge using JSON-RPC over stdio, with Content-Length framing. On first backend use, the plugin creates a virtual environment from system Python, installs the latest released `claude-agent-sdk` using pip, and runs the bridge with that interpreter. SDK 0.2.170 bundled Claude Code 2.1.306 in the tested environment. A separate Claude Code installation is not required.

## Authentication and billing

The SDK is an official integration mechanism, but that is not a blanket guarantee about account restrictions, subscription eligibility, or billing.

Anthropic's SDK overview currently says: "Unless previously approved, Anthropic does not allow third party developers to offer claude.ai login or rate limits for their products, including agents built on the Claude Agent SDK." It directs integrations to API-key authentication. That is relevant to distributing this plugin; it does not by itself settle every case of personal local use.[3]

This candidate reuses runtime authentication rather than copying credentials. In the isolated installation test, the bundled runtime recognized an existing Claude Max login and completed a Haiku request without copying tokens into the test profile. Other accounts and environments may differ. If a login is needed, `:NvClaude login` delegates to the bundled runtime's official authentication flow; the plugin has no OAuth client of its own.

API-key authentication is a documented SDK path and bills as API usage. This candidate refuses an `ANTHROPIC_API_KEY` in the Neovim process rather than silently switching to paid API-key billing. `:NvClaude info` shows the provider and subscription class reported by the runtime when available and marks billing as unverified when it cannot be independently checked.

## Install this candidate

Neovim 0.10+ and Python 3.10+ are required by the APIs and SDK used here. This candidate was exercised with Neovim 0.12.4 and Python 3.14.6 on Linux. With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  'PsychedelicShayna/nvim-claude',
  branch = 'experimental/benchmark-sol-6-high-neopi-20261021T164637Z-b89c2c62',
  main = 'nvim-claude',
  opts = {},
}
```

`:NvClaude` and default mappings register at setup without contacting Claude. The first request provisions the Python environment asynchronously under `stdpath('data')/nvim-claude`; session metadata lives under `stdpath('state')/nvim-claude`. `:NvClaude update` explicitly upgrades the SDK. To choose a different interpreter, set `opts = { python = '/path/to/python3' }`. Switching candidate branches needs a Neovim restart so old Lua modules and bridge processes are gone.

Existing mappings remain yours unless you explicitly configure an override. For example, `opts = { keys = { generate = '<leader>i', replace = false, generate_insert = '<C-g>i' } }` maps generation to the familiar key, disables replacement mappings, and opts into an Insert-mode action. Set `keys = false` to disable every plugin mapping while keeping `:NvClaude`.

Use `:NvClaude login` for the bundled runtime's official interactive authentication command. It opens a terminal tab. A subscription session may work when the bundled runtime recognizes your existing Claude Code login; an API key uses separate paid API billing, and the plugin never supplies one automatically.

The 100k local budget currently uses the runtime's measured occupancy, a UTF-8 input-size estimate, and a reserved overhead margin. Claude Code does not expose a verified per-request hard input cap through this SDK. The plugin reports this as an estimate, not as a guaranteed Haiku pricing ceiling. Large requests are refused or sent as labeled excerpts; choose a different model or budget deliberately if this does not meet your billing requirement.

## Usage

The default `<leader>c` namespace coexists with the owner's existing `<leader>i` mappings. The table names every default action; Insert-mode generation is disabled unless configured.

Here, `x` means Visual mode, `n` Normal mode, and `i` Insert mode.

| Mode | Mapping | Action |
| --- | --- | --- |
| x | `<leader>c` | Short form of selection replacement. See the timing caveat below. |
| x | `<leader>cc` | Replace the selection using the instruction entered in a cursor-local float. |
| n | `<leader>c`, `<leader>cc` | Reuse the previous valid selection in this buffer for replacement. Report when there is no valid target. |
| x | `<leader>ca` | Ask about the selection. Stream the answer into a float without changing the source buffer. |
| n | `<leader>ca` | Continue the last selected-ask target when it is still valid in this buffer and no replacement or generation has intervened. Otherwise ask generally. |
| n, i | `<leader>ci` | Generate text at the captured insertion point. Insert-mode mapping is opt-in so ordinary typing is not delayed by a leader prefix. |
| n | `<leader>cm` | Choose a model from the catalogue exposed by the runtime, then its supported effort and the plugin's context limit. |
| n | `<leader>cM` | Enter a model expression manually. |
| n | `<leader>cC` | `:NvClaude clear`: discard the active conversation's working context. |
| n | `<leader>cn` | `:NvClaude new`: start a separate conversation. |
| n | `<leader>cS` | `:NvClaude sticky`: toggle automatic persistence for conversations. |
| n | `<leader>cs` | `:NvClaude save`: retain the current conversation for later resumption. |
| n | `<leader>cx` | `:NvClaude info`: show context usage, model, persistence, and cache information in a float near the cursor. |
| n | `<leader>cl` | `:NvClaude list`: pick a saved conversation to resume. |

All actions are available through `:NvClaude` with command completion. The prompt accepts multiline input: Ctrl-S submits in Insert or Normal mode, Enter submits in Normal mode, and Normal-mode Escape dismisses. In an answer float, `q` or Escape closes it; `:NvClaude result` reopens the last answer or unapplied result. `:NvClaude compact` requests a real runtime compaction; `:NvClaude cancel` interrupts a request without applying its partial edit.

### Mapping timing

Native Neovim mappings cannot distinguish a short mapping merely by how quickly you typed it. If `<leader>c` is both an action and a prefix for `<leader>cc`, Neovim normally waits for another key or the mapping timeout. `'timeoutlen'` controls that wait. WhichKey's display delay is a separate setting.[4]

The baseline uses native prefix behavior, with `<leader>cc` as the unambiguous action. It does not install a custom fast-tap dispatcher or change global mapping timeouts. The existing `<leader>i` interaction remains the usability reference.

Normal-mode `<leader>ca` uses the last content action and target validity, not typing speed, to distinguish a selected-ask follow-up from a general question. `:NvClaude ask` always asks generally; `:NvClaude ask previous` explicitly reuses the selected-ask target or reports that none is available. These are the specification's deterministic replacements for the original draft's timing-dependent meanings.

### Models, effort, and context limits

Manual expressions use:

```text
claude-haiku-5-5[100k]:low
claude-opus-4-6[1m][500k]:high
```

In the first example, the model is `claude-haiku-5-5`, the requested effort is `low`, and `100k` is the plugin's context budget. In the second, `claude-opus-4-6[1m]` is the runtime model selector, while `500k` is the plugin budget. The plugin must not pass its local budget suffix to the SDK as part of the model ID.

A recognized native `[1m]` variant stays in the runtime model name. `[limit=100k]` always marks a plugin-local budget. The picker uses the runtime's announced model entries and effort metadata, rather than a static catalogue; manual model IDs remain available.

The requested context presets are:

```text
50k, 90k, 100k, 124k, 150k, 164k, 200k, 224k, 256k,
258k, 274k, 278k, 300k, 374k, 378k, 384k, 412k, 456k,
500k, 512k, 600k, 650k, 700k, 750k, 800k, 850k, 900k,
950k, 980k
```

The picker also offers "model default". A local budget cannot enlarge a model's physical window. The budget reservation is intentionally conservative and can reject a request that might in practice have fit. It is not proof of a hard pricing boundary; read the installation note above before relying on it for paid API use.

## Conversations and caching

Follow-ups reuse the SDK session. After a replacement, another Normal-mode replacement targets the newly inserted passage, provided intervening edits have not changed it.

Three different things are involved:

- **Conversation history** is what the SDK sends back to the model on later turns.
- **Prompt caching** lets the provider reuse computation for an unchanged prefix. A cache miss changes cost and latency, not whether history exists.
- **Persistence** determines whether the plugin retains a conversation for later resumption.

Current Claude Code documentation says main Agent SDK turns normally request a one-hour cache TTL within included subscription usage, and five minutes with usage credits, an API key, or a cloud provider. Overrides and runtime versions can change this. Direct API caching also supports both five-minute and one-hour TTLs.[5]

Unsaved sessions expire after an estimated cache-reuse interval inferred from observed usage. Where that is unknown, the plugin uses five minutes and labels the estimate. It makes no cache-warming model requests.

Saved conversations survive inactivity. Sticky mode makes conversations persistent automatically. A cold saved conversation can still be resumed, but rebuilding its cache may cost more.

- `:NvClaude clear` clears active working history. It does not delete Anthropic's server-side cache or erase saved conversations from the list.
- `:NvClaude new` starts another conversation, leaving a saved previous conversation available.
- `:NvClaude save` retains the current conversation.
- `:NvClaude sticky [on|off]` controls automatic persistence; with no argument, it toggles.
- `:NvClaude compact` summarizes the active context. Compaction is lossy and may itself use tokens.
- `:NvClaude info` separates current context occupancy from cumulative usage and labels estimated cache information.
- `:NvClaude list` shows saved conversations, newest first, as `YY:MM:DD:HH:MM:SS - <Initial prompt...>`.

The SDK writes transcripts to disk by default.[6] The plugin tracks its own session IDs, keeps saved sessions resumable after restarting Neovim, and deletes unsaved sessions when replaced or on the next launch after an unclean exit. It does not sweep unrelated Claude Code sessions or erase remote/provider-side records.

## Output character handling

The original `watermarks` command name is retained, but this feature is **punctuation normalization**, not AI detection or watermark removal. An em dash is an ordinary Unicode punctuation character, not evidence that text came from a model.

- `:NvClaude watermarks allow` leaves output unchanged. This is the default.
- `:NvClaude watermarks remove` removes characters in an explicit, documented character set.
- `:NvClaude watermarks replace` substitutes those characters with configured ASCII equivalents.

This is about navigation: `f-` does not find an em dash. It is not a reason to strip arbitrary Unicode, accents, mathematical notation, or non-Latin text. The exact initial character map is specified in the spec.

Normalization applies only to displayed or inserted output. The raw assistant reply stays unchanged in conversation history. If the next request includes a buffer diff, that diff describes the actual normalized text in the buffer, so Claude can see what was really applied without rewriting earlier messages.

## Editing the system prompt

`:NvClaude system modify` opens the current prompt in an editable scratch buffer. Write the buffer to change subsequent requests in this Neovim instance; `:NvClaude system default` restores the shipped resource. Overrides do not persist across restarts. The runtime's `snapshot = false` setting and reconnection of the same SDK session apply the changed prompt on the next turn while keeping its history, at the cost of invalidating the cached prefix.

The [specification](SPEC.md#model-input-and-output-contract) contains the replacement system prompt. It defines edit targets separately from supporting context, treats buffer contents as data, and distinguishes snapshots from diffs. Ask returns streaming prose. Editing returns a validated JSON result containing each target's replacement text, or a clarification that changes no buffer. Only decoded replacement text is inserted; the JSON envelope is not.

## Sources

These references support the factual SDK, pricing, and cache details above.

1. [Haiku 5.5 context and pricing](https://code.claude.com/docs/en/model-config#haiku-5-5-context-window-and-pricing), [API prompt-caching pricing](https://platform.claude.com/docs/en/build-with-claude/prompt-caching#pricing).
2. [Python SDK repository and prerequisites](https://github.com/anthropics/claude-agent-sdk-python), [TypeScript SDK terms](https://github.com/anthropics/claude-agent-sdk-typescript#license-and-terms).
3. [Agent SDK overview and authentication restriction](https://code.claude.com/docs/en/agent-sdk/overview).
4. Neovim `:help map-ambiguous`, `:help timeoutlen`, and [`:help map-nowait`](https://neovim.io/doc/user/map.html#map-nowait).
5. [Claude Code cache lifetime](https://code.claude.com/docs/en/prompt-caching#cache-lifetime), [API prompt caching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching).
6. [SDK sessions and persistence](https://code.claude.com/docs/en/agent-sdk/sessions), [Python SDK reference](https://code.claude.com/docs/en/agent-sdk/python).

## License

See [LICENSE](LICENSE) for the GNU General Public License, version 3.
