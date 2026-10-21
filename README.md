# nvim-claude

A personal Neovim plugin for quick, deliberate collaboration with Claude while editing text. Select something, open a small prompt float near the cursor, say what you want, and keep writing.

**This repository currently describes the plugin we intend to build. The commands below are proposed behavior, not an installed implementation.** The [specification](SPEC.md) separates requirements, proposed implementation choices, and questions still to settle.

## What it is

This is not a chat sidebar or an autonomous coding agent. I want four things:

1. Claude's opinion on a selection.
2. A quick general question, with follow-ups when useful.
3. A transformation of selected text, such as formatting a list or cleaning up code.
4. New text inserted at the cursor, such as a sentence continuation or generated code.

The reference is the inline workflow in my personal Neovim configuration. I press `<leader>i` to generate at the cursor or replace a visual selection, and `<leader>I` to choose a model. That interaction already works well. Its implementation lives in `lua/usercmds/nervgen.lua`, uses `:NervGen`, and calls my unreleased `inf` CLI. This plugin will keep the small, cursor-local interaction and replace that backend with the Python Claude Agent SDK.

You choose when to invoke Claude, what it sees, and whether to continue the current conversation or start fresh. Claude gets no editing tools. Neovim applies its output to the selected range or insertion point; answers to questions stay in a float.

I have RSI, repetitive strain injury. Reducing the number of keys between a thought and an edit is the point. The plugin will live separately from my configuration so other people can use it without installing my entire setup.

## Why Claude, and why Python?

I already have Codex in my configuration, and I am developing a broader project that will eventually support multiple providers. In the meantime, I want Haiku 5.5 for fast text manipulation, reformatting, cleanup, and generation. I also find the idea of having Astra build a Claude integration funny.

The intended starting model is `claude-haiku-5-5`, with a 100,000-token prompt budget. Anthropic currently documents higher per-token pricing for Haiku 5.5 requests whose prompts exceed 100,000 tokens. Cached input counts toward that boundary too. Staying under it matters; caching alone does not avoid the higher tier. Subscription usage accounting is not necessarily identical to API pricing.[1]

The official name is **Claude Agent SDK**, singular. Anthropic provides Python and TypeScript packages. The Python SDK's source is public and MIT-licensed; that does not make the underlying Claude Code runtime open source. Both SDKs use Claude Code, whose terms and distribution are separate. I prefer Python, so that is the backend language.[2]

Lua will communicate with a local Python process over a WebSocket. Python dependencies will live in a plugin-managed virtual environment. The SDK currently requires Python 3.10 or later, and bundles a Claude Code executable. We will pin a tested SDK/runtime combination rather than assume any installed version supports the required model and features.

## Authentication and billing

The SDK is an official integration mechanism, but that is not a blanket guarantee about account restrictions, subscription eligibility, or billing.

Anthropic's SDK overview currently says: "Unless previously approved, Anthropic does not allow third party developers to offer claude.ai login or rate limits for their products, including agents built on the Claude Agent SDK." It directs integrations to API-key authentication. That is relevant to distributing this plugin; it does not by itself settle every case of personal local use.[3]

The desired personal workflow is to use the installed Claude Code authentication where supported. We still need to verify that path with the chosen runtime and account. If a login command is needed, it should delegate to Claude Code's official authentication flow. The plugin should not implement its own OAuth client or copy and maintain refresh tokens.

API-key authentication is a documented SDK path and bills as API usage. The plugin must make the active authentication/billing mode visible when known, report uncertainty when it is not known, and never silently switch from subscription credentials to a paid API key.

## Proposed usage

The draft uses a `<leader>c` namespace so it can coexist with my current `<leader>i` mappings. Mappings will be configurable. Keeping the familiar `i`/`I` interaction is also an option; installing the plugin must not overwrite my existing mappings without an explicit configuration choice.

Here, `x` means Visual mode, `n` Normal mode, and `i` Insert mode. Mode-specific insert behavior and selection tracking are defined in the spec.

| Mode | Mapping | Action |
| --- | --- | --- |
| x | `<leader>c` | Short form of selection replacement. See the timing caveat below. |
| x | `<leader>cc` | Replace the selection using the instruction entered in a cursor-local float. |
| n | `<leader>c`, `<leader>cc` | Reuse the previous valid selection for replacement, as requested in the original draft. The alternative of generating at the cursor, like the existing `<leader>i`, remains a design choice. |
| x | `<leader>ca` | Ask about the selection. Stream the answer into a float without changing the source buffer. |
| n | `<leader>ca` | Ask a general question. Reusing the last visual ask target needs an explicit rule; see below. |
| n, i | `<leader>ci` | Generate text at the captured insertion point. Insert-mode mapping is opt-in so ordinary typing is not delayed by a leader prefix. |
| n | `<leader>cm` | Choose a model from the catalogue exposed by the runtime, then its supported effort and the plugin's context limit. |
| n | `<leader>cM` | Enter a model expression manually. |
| n | `<leader>cC` | `:NvClaude clear`: discard the active conversation's working context. |
| n | `<leader>cn` | `:NvClaude new`: start a separate conversation. |
| n | `<leader>cS` | `:NvClaude sticky`: toggle automatic persistence for conversations. |
| n | `<leader>cs` | `:NvClaude save`: retain the current conversation for later resumption. |
| n | `<leader>cx` | `:NvClaude info`: show context usage, model, persistence, and cache information in a centered float. |
| n | `<leader>cl` | `:NvClaude list`: pick a saved conversation to resume. |

All actions will also be available through `:NvClaude`, with command completion. `:NvClaude compact` requests compaction manually.

### Mapping timing

Native Neovim mappings cannot distinguish a short mapping merely by how quickly you typed it. If `<leader>c` is both an action and a prefix for `<leader>cc`, Neovim normally waits for another key or the mapping timeout. `'timeoutlen'` controls that wait. WhichKey's display delay is a separate setting.[4]

The desired quick invocation is still a requirement. The spec proposes retaining native prefix behavior initially, with `<leader>cc` as the unambiguous action, and leaves a custom fast-tap dispatcher as an explicit alternative. The existing `<leader>i` interaction should be the usability reference, not a timing claim about what its implementation does.

Similarly, a normal-mode `<leader>ca` cannot acquire two different meanings solely from ordinary mapping lookup. General ask and reuse-the-last-visual-ask must remain distinguishable. The proposed deterministic alternative is `:NvClaude ask previous`; the original speed-sensitive behavior remains an open interaction decision.

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

There should also be a "model default" choice. A local budget cannot enlarge a model's actual context window. Automatic compaction is not, by itself, proof that no request can exceed a chosen pricing boundary. The implementation must account for the next prompt, system instructions, context, and compaction requests before promising a hard 100k ceiling.

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

The SDK writes session transcripts to disk by default.[6] "Ephemeral" therefore needs an explicit storage policy, not just omission from a picker. The spec calls out how temporary storage and saving a live conversation must be resolved before implementation.

## Output character handling

The original `watermarks` command name is retained, but this feature is **punctuation normalization**, not AI detection or watermark removal. An em dash is an ordinary Unicode punctuation character, not evidence that text came from a model.

- `:NvClaude watermarks allow` leaves output unchanged. Proposed default.
- `:NvClaude watermarks remove` removes characters in an explicit, documented character set.
- `:NvClaude watermarks replace` substitutes those characters with configured ASCII equivalents.

This is about navigation: `f-` does not find an em dash. It is not a reason to strip arbitrary Unicode, accents, mathematical notation, or non-Latin text. The exact initial character map is specified in the spec.

Normalization applies only to displayed or inserted output. The raw assistant reply stays unchanged in conversation history. If the next request includes a buffer diff, that diff describes the actual normalized text in the buffer, so Claude can see what was really applied without rewriting earlier messages.

## Editing the system prompt

`:NvClaude system modify` opens the plugin's default prompt in an editable scratch buffer. Saving it changes the prompt for subsequent requests in this Neovim session. `:NvClaude system default` restores the built-in prompt. Overrides do not automatically persist across Neovim restarts.

Changing the system prompt can invalidate the cached prefix. It does not inherently require deleting the conversation. Recent Claude Code runtimes also snapshot system prompts, so the implementation must deliberately arrange for edits to take effect, rather than merely changing a Python variable. Sticky mode controls retention, not cache validity.

The [specification](SPEC.md#model-input-and-output-contract) contains the proposed replacement system prompt. It defines the edit target separately from supporting context, treats buffer contents as data, distinguishes snapshots from diffs, and keeps generated replacement text free of explanatory wrappers.

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
