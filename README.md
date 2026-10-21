# nvim-claude

A personal Neovim plugin for quick, deliberate collaboration with Claude while editing text. Select something, open a small prompt float near the cursor, say what you want, and keep writing.

This is the independent Sol 6.1 / NeoPi benchmark candidate. It implements the cursor-local editor client and Python SDK bridge described in [SPEC.md](SPEC.md). The candidate remains unmerged pending the owner's comparison. See [the run record](docs/agents/benchmark-result.md) for exercised behavior and limitations.

## What it is

This is not a chat sidebar or an autonomous coding agent. I want four things:

1. Claude's opinion on a selection.
2. A quick general question, with follow-ups when useful.
3. A transformation of selected text, such as formatting a list or cleaning up code.
4. New text inserted at the cursor, such as a sentence continuation or generated code.

The reference is the inline workflow in my personal Neovim configuration. I press `<leader>i` to generate at the cursor or replace a visual selection, and `<leader>I` to choose a model. That implementation uses `:NervGen` and my unreleased `inf` CLI. This plugin keeps the cursor-local interaction, with a separate Python Claude Agent SDK backend and no dependency on that configuration.

You choose when to invoke Claude, what it sees, and whether to continue the current conversation or start fresh. Claude gets no editing tools. Neovim applies its output to the selected range or insertion point; answers to questions stay in a float.

I have RSI, repetitive strain injury. Reducing the number of keys between a thought and an edit is the point. The plugin will live separately from my configuration so other people can use it without installing my entire setup.

## Why Claude, and why Python?

I already have Codex in my configuration, and I am developing a broader project that will eventually support multiple providers. In the meantime, I want Haiku 5.5 for fast text manipulation, reformatting, cleanup, and generation. I also find the idea of having Astra build a Claude integration funny.

The intended starting model is `claude-haiku-5-5`, with a 100,000-token prompt budget. Anthropic currently documents higher per-token pricing for Haiku 5.5 requests whose prompts exceed 100,000 tokens. Cached input counts toward that boundary too. Staying under it matters; caching alone does not avoid the higher tier. Subscription usage accounting is not necessarily identical to API pricing.[1]

The official name is **Claude Agent SDK**, singular. Anthropic provides Python and TypeScript packages. The Python SDK's source is public and MIT-licensed; that does not make the underlying Claude Code runtime open source. Both SDKs use Claude Code, whose terms and distribution are separate. I prefer Python, so that is the backend language.[2]

Lua communicates with one lazy Python bridge over framed JSON-RPC on stdio. On first backend use, system Python creates a plugin-owned virtual environment and pip installs the latest released `claude-agent-sdk`, including its bundled Claude Code executable. Later launches reuse that environment. Startup and keymaps need neither credentials nor a network connection. Installation holds an OS lock and publishes a ready marker only on success.

## Authentication and billing

The SDK is an official integration mechanism, but that is not a blanket guarantee about account restrictions, subscription eligibility, or billing.

Anthropic's SDK overview currently says: "Unless previously approved, Anthropic does not allow third party developers to offer claude.ai login or rate limits for their products, including agents built on the Claude Agent SDK." It directs integrations to API-key authentication. That is relevant to distributing this plugin; it does not by itself settle every case of personal local use.[3]

By default the bridge requests subscription authentication and clears inherited API-key/provider selectors in its child environment. It reuses the bundled runtime's supported credential discovery without copying credentials. This path was exercised with existing local subscription authentication. `:NvClaude login` opens the bundled CLI's official `auth login` flow in a terminal; the plugin does not implement OAuth.

API billing is opt-in through `billing = "api"`, which allows the inherited provider environment. `:NvClaude info` reports the known credential source and billing uncertainty. Subscription eligibility and restrictions remain Anthropic's decision.

## Installation

Requires Neovim 0.11+ and Python 3.10+ with venv and pip on Linux or macOS. This candidate was exercised on Neovim 0.12.4 and Python 3.14.6 on Linux. The minimums follow the APIs and SDK requirements; older supported versions and macOS were not exercised.

The shared Lua entry point is `require("nvim-claude").setup(opts)`. lazy.nvim uses `main = "nvim-claude"` and `opts = {}` to invoke setup. Commands and the default bindings below must appear before authentication succeeds. Override individual mappings through `opts.keys`, disable one with `false`, or set `keys = false` to disable all plugin mappings. The [specification](SPEC.md#installable-plugin-deliverable) defines the option names and portability checks.

```lua
{
  "PsychedelicShayna/nvim-claude",
  branch = "experimental/benchmark-sol-6-1-neopi-20261021-7b29e6",
  main = "nvim-claude",
  opts = {},
}
```

Restart Neovim when switching candidates. Do not retain another candidate's loaded Lua modules or bridge process.

Options are separate raw fields, not shorthand expressions:

```lua
opts = {
  model = "claude-haiku-5-5",
  effort = "low",                 -- false omits effort for an unknown manual model
  context_limit_tokens = 100000,  -- false chooses the physical model default
  billing = "subscription",      -- "api" explicitly permits provider/API environment credentials
  python = "python3",            -- optional system Python executable
  keys = {
    generate = "<leader>i",
    model = "<leader>I",
    replace_short = false,
    generate_insert = false,     -- opt-in Insert mapping, for example "<C-g>i"
  },
}
```

`keys = false` disables all mappings. Omitted actions retain the defaults below. Existing exact user mappings are preserved unless an action has an explicit replacement in `keys`. Repeated setup replaces only mappings still owned by the plugin. No timeout or WhichKey setting is changed.

Runtime files live under `stdpath("data")/nvim-claude` and `stdpath("state")/nvim-claude`. Optional `data_dir` and `state_dir` override those locations. After restarting Neovim, `:NvClaude setup update` explicitly updates the SDK. A failed setup reports Python/pip/network diagnostics and remains unready.

## Specified usage

The baseline uses a `<leader>c` namespace so it can coexist with my current `<leader>i` mappings. Mappings will be configurable. Keeping the familiar `i`/`I` interaction is also an option; installing the plugin must not overwrite my existing mappings without an explicit configuration choice.

Here, `x` means Visual mode, `n` Normal mode, and `i` Insert mode. Mode-specific insert behavior and selection tracking are defined in the spec.

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
| n | `<leader>cx` | `:NvClaude info`: show context usage, model, persistence, and cache information in a centered float. |
| n | `<leader>cl` | `:NvClaude list`: pick a saved conversation to resume. |

All actions are available through `:NvClaude`, with command completion. `:NvClaude compact` requests real runtime compaction; `:NvClaude cancel` interrupts the active request without applying a partial edit. `:NvClaude result` reopens the last answer or retained edit result. Closing a float never cancels its request. Ctrl-S submits a prompt in either mode; Normal Enter also submits, Insert Enter adds a newline, and Normal Escape closes it. Answers use Normal `q` or Escape to close and restore the origin window.

Prompt floats grow with multiline input, up to ten lines and the available screen height.

An empty generation completes without changing the buffer or its undo history. Missing saved runtime transcripts are reported rather than silently replacing history with an empty conversation.

Blockwise edits preserve unselected virtual cells around partial tabs and wide characters. The request describes both the selected display cells and their underlying UTF-8 span, so the model does not mistake that intentional difference for stale text.

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

In the first example, the model is `claude-haiku-5-5`, the requested effort is `low`, and `100k` is the plugin's context budget. In the second, `claude-opus-4-6[1m]` is the runtime model selector, while `500k` is the plugin budget. The plugin must not pass its local budget suffix to the SDK as part of the model ID.

A single recognized model-variant suffix such as `[1m]` must remain intact. The parsing rules, including an unambiguous explicit-limit spelling, are in the spec. Effort support is model-dependent; the UI must not advertise unsupported levels as though they work.

The requested context presets are:

```text
50k, 90k, 100k, 124k, 150k, 164k, 200k, 224k, 256k,
258k, 274k, 278k, 300k, 374k, 378k, 384k, 412k, 456k,
500k, 512k, 600k, 650k, 700k, 750k, 800k, 850k, 900k,
950k, 980k
```

The picker also offers model default. A local budget cannot enlarge the model's physical window.

The pre-dispatch guard counts the completed prefix from provider-reported input, cached input, and output tokens when available. New text and system instructions use a conservative UTF-8 byte bound, with a separate 16,384-token runtime/framing allowance. Uncertain delivery or model changes invalidate the measured prefix; the bridge then counts owned transcript text conservatively. Runtime context occupancy remains a separately labeled estimate.

The runtime is limited to 8,192 output tokens, which must also fit its physical context. Compaction is requested before the next edit would exceed the budget, and the compaction call is budgeted too. A fresh snapshot or explicitly incomplete excerpt follows compaction. Targets and instructions are never silently truncated. A whole-document task that cannot fit is refused.

This is a conservative host guard, not a provider-side input-token setting. It can refuse text that an exact tokenizer would fit. The runtime allowance is explicit rather than a proof about arbitrary future runtime changes. Effective tools, MCP, skills, plugins, agents, and memory metadata are checked, and reported input usage is audited against the dispatch bound.

## Conversations and caching

Follow-ups should work. After "make this more formal," I should be able to ask "less stiff" without restating the task or selecting everything again.

Three different things are involved:

- **Conversation history** is what the SDK sends back to the model on later turns.
- **Prompt caching** lets the provider reuse computation for an unchanged prefix. A cache miss changes cost and latency, not whether history exists.
- **Persistence** determines whether the plugin retains a conversation for later resumption.

Current Claude Code documentation says main Agent SDK turns normally request a one-hour cache TTL within included subscription usage, and five minutes with usage credits, an API key, or a cloud provider. Overrides and runtime versions can change this. Direct API caching also supports both five-minute and one-hour TTLs.[5]

The intended ephemeral policy is to start fresh after the expected cache-reuse interval expires. That is a plugin decision, not something cache expiry forces. Where the actual TTL is unknown, the UI must say the countdown is an estimate. There will be no background requests just to keep a cache warm.

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

Prompt changes reconnect the same SDK session with `snapshot=False`, preserving its runtime transcript while applying the new prompt on the next turn. File baselines are invalidated, so the next document-bearing request sends a fresh snapshot or explicit excerpt. Prefix invalidation can increase cost. Changing a prompt while a turn runs is rejected with the draft retained.

The [specification](SPEC.md#model-input-and-output-contract) contains the replacement system prompt. It defines edit targets separately from supporting context, treats buffer contents as data, and distinguishes snapshots from diffs. Ask returns streaming prose. Editing returns a validated JSON result containing each target's replacement text, or a clarification that changes no buffer. Only decoded replacement text is inserted; the JSON envelope is not.

## Sources

These references support the factual corrections, not a claim that the plugin has been implemented or tested.

1. [Haiku 5.5 context and pricing](https://code.claude.com/docs/en/model-config#haiku-5-5-context-window-and-pricing), [API prompt-caching pricing](https://platform.claude.com/docs/en/build-with-claude/prompt-caching#pricing).
2. [Python SDK repository and prerequisites](https://github.com/anthropics/claude-agent-sdk-python), [TypeScript SDK terms](https://github.com/anthropics/claude-agent-sdk-typescript#license-and-terms).
3. [Agent SDK overview and authentication restriction](https://code.claude.com/docs/en/agent-sdk/overview).
4. Neovim `:help map-ambiguous`, `:help timeoutlen`, and [`:help map-nowait`](https://neovim.io/doc/user/map.html#map-nowait).
5. [Claude Code cache lifetime](https://code.claude.com/docs/en/prompt-caching#cache-lifetime), [API prompt caching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching).
6. [SDK sessions and persistence](https://code.claude.com/docs/en/agent-sdk/sessions), [Python SDK reference](https://code.claude.com/docs/en/agent-sdk/python).

## License

See [LICENSE](LICENSE) for the GNU General Public License, version 3.
