# nvim-claude specification

This document describes what nvim-claude must do and what counts as done. It replaces an earlier draft that was written as a benchmark baseline. That draft turned a cost preference into a hard technical gate, and implementers graded working plugins as failures because of it. The owner's intent is recorded below. Where this document gives a mechanism, it is a suggestion unless it says "must".

## What success means

An implementation succeeds when all of these hold:

1. **It installs like any plugin.** Adding `PsychedelicShayna/nvim-claude` to lazy.nvim with `main = "nvim-claude"` and `opts = {}` installs it, registers `:NvClaude` and the default mappings, and creates its own Python environment with the latest `claude-agent-sdk` on first use. No private config, local checkout, or separate Claude Code install is needed.
2. **The three operations work with Haiku 5.5.** Replace a selection, generate at the cursor, and ask (about a selection or in general) all work against the real SDK, with `claude-haiku-5-5` on `low` effort as the default.
3. **Follow-ups remember.** Within a warm conversation, "no, change it back" or "less formal" acts on the previous result without reselecting or restating.
4. **Context stays roughly near the limit.** When the conversation roughly reaches the configured context limit (100k by default for Haiku), the plugin does something about it: compact, start fresh, or ask the user which. Any working mechanism counts. Overshooting to 101k or 110k is fine. See [Context limit](#context-limit).
5. **The model is switchable.** A picker shows models (live catalogue when available, otherwise a fallback list), then effort, then context limit. Manual entry accepts exact slugs, including ones the picker doesn't list.
6. **The model gets no tools and no environment.** It sees the plugin's system prompt, the instruction, and the buffer text the plugin sends. No tools, no CLAUDE.md or AGENTS.md, no settings or memory files, no project crawling.
7. **The prompt float doesn't get in the way.** It reuses one input buffer with its undo history across invocations, supports Normal-mode navigation, and never blocks `:qa` with a "no file name" or unsaved-buffer warning.

Everything else in this document is desirable behavior. Missing a desirable item is a bug to fix later, not a failed implementation. A limitation found in the SDK should be worked around or reported, not used as a reason to disable a core operation.

## Product

nvim-claude is a cursor-local editing companion for Neovim backed by the Python Claude Agent SDK. The user invokes every request. There is no chat sidebar, no autonomous agent, and no dependency on the old `inf` CLI.

| Operation | Input | Result |
| --- | --- | --- |
| Ask | A question, optionally about a selection | Answer streams into a float; buffer unchanged |
| Replace | A selection plus an instruction | The selection is replaced |
| Generate | The cursor position plus an instruction | New text is inserted at the cursor |

The reference interaction is NervGen (`lua/usercmds/nervgen.lua` in the owner's config): `<leader>i` opens a small float at the cursor, generates in Normal mode, and replaces in Visual mode. The new plugin keeps that feel with a Claude backend.

## Editor interaction

### Default mappings

All mappings are configurable through `opts.keys`. A string replaces a mapping, `false` disables it, and `keys = false` disables every mapping. Setup must not overwrite a mapping the user already defined unless they configured that key explicitly. Calling setup twice must not duplicate anything.

| Key option | Default | Modes | Action |
| --- | --- | --- | --- |
| `replace` | `<leader>cc` | n, x | Replace the selection (Normal: reuse the last selection in this buffer) |
| `replace_short` | `<leader>c` | n, x | Same as `replace` |
| `ask` | `<leader>ca` | n, x | Ask about the selection (Visual) or ask generally (Normal) |
| `generate` | `<leader>ci` | n | Generate at the cursor |
| `generate_insert` | `false` | i | Generate at the cursor from Insert mode (opt-in) |
| `model` | `<leader>cm` | n | Model picker |
| `model_manual` | `<leader>cM` | n | Manual model expression |
| `clear` | `<leader>cC` | n | Clear the working conversation |
| `new` | `<leader>cn` | n | Start a new conversation |
| `sticky` | `<leader>cS` | n | Toggle sticky persistence |
| `save` | `<leader>cs` | n | Save the current conversation |
| `info` | `<leader>cx` | n | Show context and session info |
| `list` | `<leader>cl` | n | Pick a saved conversation to resume |

Use native mapping resolution. Do not change `timeoutlen` or WhichKey settings. In Normal mode, `<leader>ca` may continue the previous selected-ask target when that was the last content action; otherwise it asks generally.

### Prompt float

- Capture the operation, buffer, and target before opening the float. Highlight the target while the float is open.
- Open a small float near the cursor, in Insert mode. It grows with multiline input and stays on screen.
- `<C-s>` submits from Insert or Normal mode. `<CR>` submits from Normal mode. `<Esc>` in Normal mode or `q` closes without submitting.
- Reuse a single input buffer so its undo tree survives across invocations. Clear visible text with an ordinary undoable edit.
- The input buffer is scratch input: `buftype=nofile`, hidden when not shown, unlisted. It must never block quitting Neovim.

### Answer float

Ask output streams into a float. `q` or `<Esc>` closes it and returns to the source window. Closing the float does not cancel the request. Text in the answer float can be selected and yanked normally.

### Applying edits

- Edits apply once, after the response completes. One `u` undoes the whole edit.
- Track the target with extmarks so unrelated edits elsewhere in the buffer do not break it.
- If the target text changed while the request ran, do not overwrite it. Show the result in a float instead.
- After a replacement, the remembered target becomes the inserted text, so a follow-up acts on the result.
- Generate inserts at the captured position without duplicating the character under the cursor or adding a stray newline.
- Characterwise and linewise selections must work, including multibyte text and selections made backwards. Blockwise selections are desirable; a reasonable fallback is acceptable.
- `:NvClaude cancel` stops the active request. A cancelled request makes no edit.

## Backend

### Python environment

On first backend use, find `python3` (or `opts.python`), create a venv under `stdpath("data")/nvim-claude/venv`, and `pip install` the latest `claude-agent-sdk`. Do this asynchronously with visible progress, and report failures clearly. Reuse the venv afterwards. `:NvClaude update` upgrades the SDK on request. Use the SDK's bundled Claude Code binary.

### Bridge

Lua talks to a long-lived Python bridge process over stdio. The wire format is up to the implementation (newline-delimited JSON is fine). Lua owns buffers, floats, keymaps, and undo. Python owns the SDK client and the conversation. Keep one warm `ClaudeSDKClient` per conversation so follow-ups do not pay startup cost. Do not spawn Python or reinstall anything per request.

### No tools, no environment

Configure the SDK so the model has nothing but the plugin's context:

- `tools=[]`, `mcp_servers={}`, `strict_mcp_config=True`.
- `setting_sources=[]`, so no user, project, or local settings, CLAUDE.md, or memory load.
- A custom `system_prompt` string, not the Claude Code preset.
- `cwd` set to a plugin-owned directory, not the user's project.

The SDK's init message lists the effective tools; it should be empty.

### Authentication

Use whatever credentials the bundled Claude Code already finds (the user's existing Claude Code login). If a request fails for lack of authentication, say so and point to `claude login` or `:NvClaude login`. Do not implement OAuth or store tokens in the plugin.

## Models

The picker sequence is model, then effort, then context limit. Cancelling any step keeps the current setting.

- Use `get_server_info()["models"]` when it returns entries; each entry carries `value`, `displayName`, and `supportedEffortLevels`.
- Merge in a fallback list (the owner's NervAgent Claude roster plus `claude-haiku-5-5`) and any `opts.models` entries. Discovery failing must not block editing.
- Manual entry (`<leader>cM` or `:NvClaude model <expr>`) accepts an exact slug.

### Model expressions

`slug[limit]:effort`, where the last bracket group holding a number with `k` or `m` is the plugin's context limit, and a trailing `:low|medium|high|xhigh|max` is the effort. Native selectors such as `[1m]` stay part of the slug.

| Expression | Model | Limit | Effort |
| --- | --- | --- | --- |
| `claude-haiku-5-5[100k]:low` | `claude-haiku-5-5` | 100,000 | low |
| `claude-opus-4-6[1m][500k]:high` | `claude-opus-4-6[1m]` | 500,000 | high |
| `claude-opus-4-6[1m]:high` | `claude-opus-4-6[1m]` | unchanged | high |
| `claude-fable-5-1[318k]` | `claude-fable-5-1` | 318,000 | unchanged |

`[1m]` alone after a slug is a native selector, not a limit. When in doubt, keep the bracket in the slug and let the SDK reject it.

## Conversations

### Lifetime

Follow-ups reuse the active conversation while it is warm. An unsaved conversation is ephemeral: after the cache window expires (default 60 minutes of inactivity, configurable), the next request starts a fresh conversation. Saved conversations do not expire. No background requests to keep a cache warm.

### Commands

| Command | Behavior |
| --- | --- |
| `new` | Start a new conversation. An unsaved previous one is dropped. |
| `clear` | Same as `new` for the working context. Saved records stay saved. |
| `save` | Keep the current conversation for later resumption. |
| `sticky [on\|off]` | Automatically save every conversation. No argument toggles. |
| `compact` | Ask the runtime to compact the conversation (`/compact`). |
| `list` | Pick a saved conversation, newest first, shown as `YY:MM:DD:HH:MM:SS - <first prompt>`, and resume it. |
| `info` | Show model, effort, context limit, current context use, conversation state, and SDK/CLI versions. |
| `cancel` | Stop the active request. |
| `system modify` / `system default` | Edit the system prompt for this Neovim session; saving the buffer applies it. `default` restores the shipped prompt. |
| `watermarks allow\|remove\|replace` | Output punctuation normalization (below). |
| `update` | Upgrade the SDK in the plugin venv. |
| `login` | Run the bundled CLI's login flow. |

Saving and resuming should use the SDK's own session IDs and `resume`. Deleting unsaved transcripts is a nice-to-have; it is not required.

### Context limit

The context limit is a cost control, managed by the client. It exists because Haiku 5.5 costs more per token once a prompt passes 100k tokens. It does not need to be a hard ceiling, an exact token count, or a server-side model variant. A 318k limit on Fable is just as valid, since the client is the one enforcing it.

When the conversation reaches or roughly passes the limit, the plugin should ask:

> Context limit reached (104k / 100k). **N**ew conversation or **c**ompact?

The default answer is a new conversation. The pending request is not lost: after the user chooses, it runs in the new or compacted conversation. `opts.on_limit` can be set to `"ask"` (default), `"new"`, or `"compact"` to skip the question.

Any of these mechanisms satisfies the requirement, alone or combined:

- Checking `get_context_usage()` (or the last result's usage) after a turn and acting before the next request.
- Setting `CLAUDE_CODE_AUTO_COMPACT_WINDOW` (or the percentage override) so the runtime compacts on its own.
- Starting a fresh conversation once the limit is crossed.

Compaction and handoff keep some memory; a fresh conversation keeps none. Say which one happened. If compaction fails, fall back to a fresh conversation rather than repeating the attempt.

## Model input and output

### Request

Send each request as a JSON object in the user message so buffer text is never confused with the plugin's own markers:

```json
{
  "operation": "replace",
  "instruction": "Replace the placeholder with quick.",
  "document": {"name": "notes.md", "filetype": "markdown"},
  "context": {"kind": "snapshot", "text": "The ... brown fox jumps over the lazy dog.\n"},
  "targets": [{"id": "t0", "text": "..."}]
}
```

Send the buffer (or a bounded excerpt around the target for very large files) when the conversation has not seen it, and after compaction or a fresh start. On later turns, sending only the target and a short excerpt, or a diff, is enough. The exact context strategy is up to the implementation; keeping repeated full-buffer sends out of a long conversation helps the context limit.

### Response

Ask responses are ordinary prose, streamed. Replace and generate responses are one JSON object:

```json
{"status": "ok", "replacements": [{"id": "t0", "text": "quick"}]}
```

or `{"status": "needs_input", "message": "..."}` when the model needs clarification. The plugin inserts only the decoded `text`, verbatim. A response that is not valid JSON is shown in a float, not inserted. Strip one surrounding code fence from the JSON if the model adds one.

The shipped system prompt lives in a static file in the plugin and explains this contract to the model.

### Output punctuation policy

`watermarks` defaults to `allow`. `replace` maps em/en dashes to `-`, curly quotes to straight quotes, `…` to `...`, and non-breaking spaces to spaces. `remove` deletes those characters. The policy applies to inserted and displayed text only, never to conversation history.

## Desirable acceptance checks

These describe a good implementation. They are not a pass/fail gate beyond [What success means](#what-success-means).

1. A clean lazy.nvim config installs the plugin from GitHub and provisions the venv without freezing the editor.
2. Replace changes only the selection; one undo restores it.
3. Generate inserts at the cursor without duplicating text.
4. A follow-up refines the previous result.
5. Ask streams into a float and leaves the buffer untouched.
6. The model picker lists live models and accepts manual slugs with limit and effort.
7. Crossing the context limit offers new or compact, and the pending request continues afterwards.
8. `:qa` works with the prompt buffer having been used.
9. `save`, `list`, and resume bring back a conversation that remembers earlier turns.
10. `info` shows current context use against the limit.

## References

- [Python SDK](https://github.com/anthropics/claude-agent-sdk-python) and [reference](https://code.claude.com/docs/en/agent-sdk/python).
- [Model configuration, Haiku 5.5 pricing boundary, compaction window](https://code.claude.com/docs/en/model-config).
- [Claude Code cache lifetime](https://code.claude.com/docs/en/prompt-caching).
- [SDK sessions](https://code.claude.com/docs/en/agent-sdk/sessions).
- [Environment variables](https://code.claude.com/docs/en/env-vars).
