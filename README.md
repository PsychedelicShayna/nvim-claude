# nvim-claude

A personal Neovim plugin for quick, deliberate collaboration with Claude while editing text. Select something, open a small prompt float near the cursor, say what you want, and keep writing.

This branch is the independent Sol xhigh benchmark candidate. Its [run record](docs/agents/benchmark-result.md) lists exercised behavior and known limits. The candidate stays unmerged until the owner selects a winner.

## What it is

This is not a chat sidebar or an autonomous coding agent. I want four things:

1. Claude's opinion on a selection.
2. A quick general question, with follow-ups when useful.
3. A transformation of selected text, such as formatting a list or cleaning up code.
4. New text inserted at the cursor, such as a sentence continuation or generated code.

The interaction comes from the owner's existing inline workflow, without its `inf` dependency. Visual `<leader>cc` replaces the captured selection, Normal `<leader>ci` generates at the cursor, and `<leader>ca` asks in a separate answer window. A prompt opens near the cursor; Ctrl-S submits from Insert or Normal mode, Normal-mode Enter submits, and Escape dismisses it. Neovim applies a completed, validated edit to the original buffer. Claude receives no editor tools.

The plugin installs separately from the owner's private configuration. No project files are attached to a general question; a selected ask or edit supplies only the buffer explicitly invoked.

## Why Claude, and why Python?

I already have Codex in my configuration, and I am developing a broader project that will eventually support multiple providers. In the meantime, I want Haiku 5.5 for fast text manipulation, reformatting, cleanup, and generation. I also find the idea of having Astra build a Claude integration funny.

The intended starting model is `claude-haiku-5-5`, with a 100,000-token prompt budget. Anthropic currently documents higher per-token pricing for Haiku 5.5 requests whose prompts exceed 100,000 tokens. Cached input counts toward that boundary too. Staying under it matters; caching alone does not avoid the higher tier. Subscription usage accounting is not necessarily identical to API pricing.[1]

The official name is **Claude Agent SDK**, singular. Anthropic provides Python and TypeScript packages. The Python SDK's source is public and MIT-licensed; that does not make the underlying Claude Code runtime open source. Both SDKs use Claude Code, whose terms and distribution are separate. I prefer Python, so that is the backend language.[2]

Lua handles Neovim state and communicates with a Python bridge over framed JSON-RPC on stdio. First backend use creates a plugin-owned virtual environment, installs the latest released `claude-agent-sdk`, and starts its bundled Claude Code runtime. Later launches reuse the environment. No separate Claude Code installation is required.

## Authentication and billing

The SDK is an official integration mechanism, but that is not a blanket guarantee about account restrictions, subscription eligibility, or billing.

Anthropic's SDK overview currently says: "Unless previously approved, Anthropic does not allow third party developers to offer claude.ai login or rate limits for their products, including agents built on the Claude Agent SDK." It directs integrations to API-key authentication. That is relevant to distributing this plugin; it does not by itself settle every case of personal local use.[3]

Use `:NvClaude login` to open the bundled Claude Code CLI's official interactive login in a Neovim terminal. `:NvClaude info` reports the observed authentication method when available. This candidate strips inherited API keys from its bridge process by default rather than silently switching a personal subscription workflow to API billing. Login support does not guarantee subscription eligibility; Anthropic's third-party restrictions still apply.[3]

The bridge requests Claude Code safe mode and an empty effective tool/MCP list. The tested runtime reported no callable tools or MCP servers, but still announced names for installed skills, plugins and agents in initialization metadata. See the run record for that isolation caveat.

## Install this candidate

Install the branch with lazy.nvim, then restart Neovim before switching to a different candidate:

```lua
{
  "PsychedelicShayna/nvim-claude",
  branch = "experimental/benchmark-sol-6-xhigh-neopi-20261021T164647Z-d53d81bd",
  main = "nvim-claude",
  opts = {},
}
```

Verified local editor version and resolved SDK/CLI versions are listed in the [run record](docs/agents/benchmark-result.md). The runtime needs Python 3.10 or newer. `setup()` registers `:NvClaude` and default keys before provisioning or authentication. The first backend action installs into Neovim's data directory asynchronously and reports failure without freezing the editor. Set `opts.python` to select a Python interpreter explicitly.

Override just one mapping with `opts = { keys = { generate = "<leader>i", model = "<leader>I" } }`. Use `false` for one action, such as `keys = { replace_short = false }`, or `keys = false` to disable all plugin mappings. Existing mappings are left alone unless a replacement is explicitly configured.

## Usage

The default `<leader>c` mappings coexist with the owner's existing `<leader>i` bindings. Here `x` means Visual, `n` Normal, and `i` Insert. Generate in Insert mode is opt-in through `keys.generate_insert`.

| Mode | Mapping | Action |
| --- | --- | --- |
| x | `<leader>c` | Short form of selection replacement. See the timing caveat below. |
| x | `<leader>cc` | Replace the selection using the instruction entered in a cursor-local float. |
| n | `<leader>c`, `<leader>cc` | Reuse the previous valid selection in this buffer for replacement. Report when there is no valid target. |
| x | `<leader>ca` | Ask about the selection. Stream the answer into a float without changing the source buffer. |
| n | `<leader>ca` | Continue the last selected-ask target when it is still valid in this buffer and no replacement or generation has intervened. Otherwise ask generally. |
| n; i opt-in | `<leader>ci` | Generate at the captured insertion point. Configure `keys.generate_insert` to add the Insert-mode mapping. |
| n | `<leader>cm` | Choose a model from the catalogue exposed by the runtime, then its supported effort and the plugin's context limit. |
| n | `<leader>cM` | Enter a model expression manually. |
| n | `<leader>cC` | `:NvClaude clear`: discard the active conversation's working context. |
| n | `<leader>cn` | `:NvClaude new`: start a separate conversation. |
| n | `<leader>cS` | `:NvClaude sticky`: toggle automatic persistence for conversations. |
| n | `<leader>cs` | `:NvClaude save`: retain the current conversation for later resumption. |
| n | `<leader>cx` | `:NvClaude info`: show context usage, model, persistence, and cache information in a centered float. |
| n | `<leader>cl` | `:NvClaude list`: pick a saved conversation to resume. |

The same actions have `:NvClaude` subcommands and completion. `:NvClaude cancel` interrupts a running turn without applying partial edits. `:NvClaude compact` runs real SDK compaction only with a model-default budget. Claude Code disables `/compact` under its guarded context-window setting, so capped sessions refuse the command rather than make an unprotected request.

### Mapping timing

Native Neovim mappings cannot distinguish a short mapping merely by how quickly you typed it. If `<leader>c` is both an action and a prefix for `<leader>cc`, Neovim normally waits for another key or the mapping timeout. `'timeoutlen'` controls that wait. WhichKey's display delay is a separate setting.[4]

The baseline uses native prefix behavior, with `<leader>cc` as the unambiguous action. It does not install a custom fast-tap dispatcher or change global mapping timeouts. The existing `<leader>i` interaction remains the usability reference.

Normal-mode `<leader>ca` uses the last content action and target validity, not typing speed, to distinguish a selected-ask follow-up from a general question. `:NvClaude ask` always asks generally; `:NvClaude ask previous` explicitly reuses the selected-ask target or reports that none is available. These are the specification's deterministic replacements for the original draft's timing-dependent meanings.

### Models, effort, and context limits

Manual model expressions include:

```text
claude-haiku-5-5[100k]:low
claude-opus-4-6[1m][500k]:high
```

The first expression passes model `claude-haiku-5-5`, effort `low`, and a separate 100k local budget. The second keeps `[1m]` in the runtime model selector and treats the final `[500k]` as the local budget. An explicit `[limit=100k]` suffix is also supported. The picker uses runtime-announced models when the CLI supplies them; otherwise manual entry remains available. Effort support is displayed only when the runtime announces it.

The requested context presets are:

```text
50k, 90k, 100k, 124k, 150k, 164k, 200k, 224k, 256k,
258k, 274k, 278k, 300k, 374k, 378k, 384k, 412k, 456k,
500k, 512k, 600k, 650k, 700k, 750k, 800k, 850k, 900k,
950k, 980k
```

There is also a model-default choice. A selected local limit does not enlarge the model's physical window. For Haiku 5.5 at 100k, the bridge requests Claude Code's guarded context window, reserves input headroom, and refuses turns it cannot admit. It does not advertise unsupported smaller presets as safe. Guarded sessions cannot compact, so they eventually require a new conversation; see the run record for what runtime enforcement was actually observed.

## Conversations and caching

Follow-ups continue the active conversation. After "make this more formal," another request such as "less stiff" can refine the remembered replacement without selecting it again.

Three different things are involved:

- **Conversation history** is what the SDK sends back to the model on later turns.
- **Prompt caching** lets the provider reuse computation for an unchanged prefix. A cache miss changes cost and latency, not whether history exists.
- **Persistence** determines whether the plugin retains a conversation for later resumption.

Current Claude Code documentation says main Agent SDK turns normally request a one-hour cache TTL within included subscription usage, and five minutes with usage credits, an API key, or a cloud provider. Overrides and runtime versions can change this. Direct API caching also supports both five-minute and one-hour TTLs.[5]

An unsaved conversation expires after an estimated cache-reuse interval and starts fresh on its next invocation. That interval is not proof of a live provider cache entry. Saved conversations remain resumable, and there are no background cache-warming requests.

Saved conversations survive inactivity. Sticky mode makes conversations persistent automatically. A cold saved conversation can still be resumed, but rebuilding its cache may cost more.

- `:NvClaude clear` clears active working history. It does not delete Anthropic's server-side cache or erase saved conversations from the list.
- `:NvClaude new` starts another conversation, leaving a saved previous conversation available.
- `:NvClaude save` retains the current conversation.
- `:NvClaude sticky [on|off]` controls automatic persistence; with no argument, it toggles.
- `:NvClaude compact` summarizes an uncapped conversation; guarded local-budget sessions refuse it rather than silently remove their cap.
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

Changing the system prompt can invalidate the cached prefix. It does not inherently require deleting the conversation. Recent Claude Code runtimes also snapshot system prompts, so the implementation must deliberately arrange for edits to take effect, rather than merely changing a Python variable. Sticky mode controls retention, not cache validity.

The [specification](SPEC.md#model-input-and-output-contract) contains the replacement system prompt. It defines edit targets separately from supporting context, treats buffer contents as data, and distinguishes snapshots from diffs. Ask returns streaming prose. Editing returns a validated JSON result containing each target's replacement text, or a clarification that changes no buffer. Only decoded replacement text is inserted; the JSON envelope is not.

## Sources

These are upstream sources for the pricing and runtime claims. Candidate verification is recorded separately in the run record.

1. [Haiku 5.5 context and pricing](https://code.claude.com/docs/en/model-config#haiku-5-5-context-window-and-pricing), [API prompt-caching pricing](https://platform.claude.com/docs/en/build-with-claude/prompt-caching#pricing).
2. [Python SDK repository and prerequisites](https://github.com/anthropics/claude-agent-sdk-python), [TypeScript SDK terms](https://github.com/anthropics/claude-agent-sdk-typescript#license-and-terms).
3. [Agent SDK overview and authentication restriction](https://code.claude.com/docs/en/agent-sdk/overview).
4. Neovim `:help map-ambiguous`, `:help timeoutlen`, and [`:help map-nowait`](https://neovim.io/doc/user/map.html#map-nowait).
5. [Claude Code cache lifetime](https://code.claude.com/docs/en/prompt-caching#cache-lifetime), [API prompt caching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching).
6. [SDK sessions and persistence](https://code.claude.com/docs/en/agent-sdk/sessions), [Python SDK reference](https://code.claude.com/docs/en/agent-sdk/python).

## License

See [LICENSE](LICENSE) for the GNU General Public License, version 3.
