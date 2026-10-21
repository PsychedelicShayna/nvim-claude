# nvim-claude

> [!IMPORTANT]
> Round 1 metadata-only post-run correction. This candidate ran with GPT-6 Astra, `openai-codex/gpt-6-astra`, at **xhigh** effort in NeoPi.
> Original branch: `experimental/benchmark-astra-6-high-neopi-20261021-7c93b2`.
> Original delivered commit: [`7521eceaa66b4a4e0f0a6d329278c592020965ee`](https://github.com/PsychedelicShayna/nvim-claude/commit/7521eceaa66b4a4e0f0a6d329278c592020965ee).
> Corrected installable branch: [`experimental/round-1-astra-6-xhigh-neopi-20261021-7c93b2`](https://github.com/PsychedelicShayna/nvim-claude/tree/experimental/round-1-astra-6-xhigh-neopi-20261021-7c93b2).
> The branch rename and this README-only commit correct attribution after delivery. They do not change the implementation, rerun the benchmark, or rewrite the historical run record.

Cursor-local prompts for Neovim, with a Lua editor client and a Python Claude Agent SDK bridge. Ask streams into a separate float. Replacement and generation apply only validated, completed output to the captured target.

**This benchmark candidate does not pass the complete specification.** Its default 100,000-token hard budget currently refuses model requests. Claude Code 2.1.306 exposes context telemetry and automatic-compaction settings, but the inspected SDK/runtime interface does not provide an authoritative next-request token count or a hard input-token limit. The plugin does not claim that an estimate protects the Haiku pricing boundary. See [the run record](docs/agents/benchmark-result.md) for exercised behavior and unresolved acceptance criteria.

## Install

Linux or macOS, Neovim 0.11+, and Python 3.10+ with `venv` and `pip`. Verified versions are recorded in the run record. Windows is not supported because provisioning and conversation ownership use POSIX advisory locks.

```lua
{
  "PsychedelicShayna/nvim-claude",
  branch = "experimental/round-1-astra-6-xhigh-neopi-20261021-7c93b2",
  main = "nvim-claude",
  opts = {},
}
```

Restart Neovim when switching candidates. Setup registers `:NvClaude` and mappings without starting Python or requiring authentication. The first backend operation starts asynchronous provisioning in `stdpath('data')/nvim-claude/venv`, installs the latest released `claude-agent-sdk`, and reuses it thereafter. Installation errors remain visible; a file lock serializes provisioning across editor instances. The bridge uses the SDK's bundled executable, not a system Claude installation.

`:NvClaude update` explicitly upgrades the SDK. Run it in a fresh editor before starting the bridge. `:NvClaude info` reports Python, SDK and CLI versions, configuration, context telemetry, cumulative usage, persistence and estimated cache lifetime.

## Keys and prompts

| Option | Default | Modes | Action |
| --- | --- | --- | --- |
| `replace` | `<leader>cc` | Normal, Visual | Replace a current or remembered selection |
| `replace_short` | `<leader>c` | Normal, Visual | Same replacement action |
| `ask` | `<leader>ca` | Normal, Visual | Ask generally or about a selection |
| `generate` | `<leader>ci` | Normal | Insert before the captured cursor character |
| `generate_insert` | disabled | Insert | Insert at the current insertion boundary |
| `model` | `<leader>cm` | Normal | Runtime model, effort and budget picker |
| `model_manual` | `<leader>cM` | Normal | Manual model expression |
| `clear` | `<leader>cC` | Normal | Clear working context, preserving saved history |
| `new` | `<leader>cn` | Normal | Start another conversation |
| `sticky` | `<leader>cS` | Normal | Toggle automatic persistence |
| `save` | `<leader>cs` | Normal | Save active history and future completed turns |
| `info` | `<leader>cx` | Normal | Runtime and conversation information |
| `list` | `<leader>cl` | Normal | Pick a saved conversation |

Defaults preserve existing mappings. Explicit strings replace a mapping; `false` disables one. `keys = false` disables all plugin mappings. Repeated setup removes only mappings still owned by this plugin.

```lua
opts = {
  keys = {
    generate = "<leader>i",
    replace = "<leader>cc",
    replace_short = false,
    model = "<leader>I",
    generate_insert = "<C-g>i", -- opt-in
  },
  python = "python3",
  model = "claude-haiku-5-5",
  effort = "low",
  context_limit_tokens = 100000,
}
```

Native mapping resolution applies. `<leader>c` waits while a longer mapping remains possible. The plugin does not change `timeoutlen` or WhichKey.

The prompt opens near the cursor, highlights the target, and starts in Insert mode. Ctrl-S submits in either mode. Enter submits in Normal mode and creates a newline in Insert mode. Escape leaves Insert mode, then closes the prompt in Normal mode. A second submission while a turn runs retains the draft and reports that the conversation is busy.

Normal replacement requires a valid previous target in the same buffer. Normal mapped ask continues the last selected-ask chain when still valid. `:NvClaude ask` always asks generally; `:NvClaude ask previous` explicitly requests that chain. A general question has no implicit file attachment.

Answer/result floats retain their buffer when hidden. Normal `q` or Escape closes the window and restores the origin window. `:NvClaude cancel` interrupts independently of the visible float. Source edits happen once after successful completion; canceled, malformed, stale or failed results do not modify the source. Raw results remain available for inspection. Extmarks follow unrelated edits; target-content changes and undo invalidate remembered targets. Block targets carry one stable ID per row and reject multiline replacements.

## Models and budgets

The picker uses `get_server_info().models`, including its effort metadata. Manual entry remains available with `:NvClaude model manual` or `:NvClaude model <expression>`.

```text
claude-haiku-5-5[100k]:low
claude-opus-4-6[1m][500k]:high
claude-opus-4-6[1m]:high
gateway:model[limit=100k]:low
```

Model, effort and local budget remain separate. Recognized native selectors stay in the runtime slug. Unknown `[1m]` selectors require raw configuration or explicit `[limit=1m]`, rather than silently guessing a native capability. Decimal `k` and `m` mean 1,000 and 1,000,000.

A lone recognized native selector, such as `claude-opus-4-6[1m]:high`, selects the model-default local budget, as specified in the shared expression table. Add `[100k]` or `[limit=100k]` after it to request a local ceiling. The model-change notification always states the resulting budget.

Presets: 50k, 90k, 100k, 124k, 150k, 164k, 200k, 224k, 256k, 258k, 274k, 278k, 300k, 374k, 378k, 384k, 412k, 456k, 500k, 512k, 600k, 650k, 700k, 750k, 800k, 850k, 900k, 950k, 980k, and model default.

**Every numeric local budget is currently unsupported and refused before inference.** Selecting model default, or explicitly setting `context_limit_tokens = false`, removes that local ceiling. This is an explicit opt-out, not a workaround that preserves 100k protection. No uncapped model request was used for this benchmark's verification. Physical-capacity checks under model default are conservative estimates using runtime telemetry, UTF-8 byte counts and an 8,192-token overhead allowance; they are not a verified hard bound. Output reservation is 4,096 tokens.

The bridge requests thinking disabled. Runtime metadata reports that current Haiku 5.5 does not support thinking off, so this candidate cannot promise reasoning-free execution on that model.

## Conversations

One conversation and one lazy SDK client run per editor. No heartbeat or cache-warming request is sent. The estimated reuse interval is one hour when runtime metadata identifies an included first-party subscription, otherwise five minutes. Cache overrides and transitions can make that estimate wrong. Saved conversations do not expire.

- `new` and `clear` detach from the active session. Saved checkpoints remain listed; unsaved sessions are deleted using the SDK's exact-session deletion API.
- `save` retains the active conversation and future completed turns.
- `sticky on` saves the current conversation and automatically saves future ones. `sticky off` does not unsave history.
- `list` shows saved conversations newest-first, with timestamp, first prompt and stable ID. Selecting one resumes its runtime session. Editor targets are not restored from disk.
- `compact` sends the runtime `/compact` command and requires a `compact_boundary` event. It is subject to the same unsupported-budget refusal. Under model default, the bridge requests early compaction using estimated occupancy, then invalidates all file baselines. This model-backed path remains unverified.

Manifests and immutable raw turns live under `stdpath('state')/nvim-claude`. Per-conversation locks prevent two live bridges owning one saved session. Startup removes abandoned unsaved records only after acquiring their ownership lock. Runtime transcripts remain in Claude Code's normal credential-independent session storage. Cleanup calls `delete_session` with an exact recorded UUID and plugin-owned working directory; it does not sweep unrelated Claude sessions. This is lifecycle cleanup, not forensic erasure or deletion of provider-side logs/cache.

Completed context delivery advances a document baseline. Later requests send unchanged markers or append-only unified diffs when smaller and unambiguous; otherwise they send a fresh snapshot. Failures, resume, prompt changes and compaction invalidate baselines.

## Authentication and isolation

`:NvClaude login` delegates to the bundled CLI's official `auth login` flow. Use a fresh editor before starting the bridge. Existing runtime authentication is reused without copying credentials. The bridge refuses inherited API-key or cloud-provider billing variables rather than silently preferring them to subscription credentials. Remove those variables from the editor environment to use the personal login flow.

The SDK is not blanket permission to distribute subscription-backed services. Anthropic's [SDK overview](https://code.claude.com/docs/en/agent-sdk/overview) restricts third-party use of claude.ai login/rate limits without prior approval. Account eligibility and terms remain the user's responsibility.

The bridge sets `tools=[]`, `skills=[]`, `agents={}`, `plugins=[]`, strict empty MCP configuration and `setting_sources=[]`. It disables hooks, memory files, automatic memory, attachments, background tasks and automatic IDE connection. It checks context/MCP metadata before use and init tool announcements during the turn. The working directory is plugin-owned, not the edited project. Managed policy can still apply; the SDK process is not an OS sandbox.

## Presentation and system prompt

`watermarks allow` is the default. `watermarks replace` maps em/en dashes to `-`, curly single/double quotes to ASCII quotes, ellipsis to `...`, and nonbreaking space to ordinary space. `watermarks remove` deletes precisely those characters. This is punctuation normalization, not watermark detection. All other Unicode passes through. `opts.punctuation` can supply a replacement map. Only display/insertion text changes; raw assistant history is immutable.

`system modify` opens a scratch prompt buffer. `:write` applies it between turns; `system default` restores the shipped static resource. Changes are session-local. The next connection resumes the runtime session with a custom prompt and `snapshot=false`; it does not replay or rewrite raw turns. Next-request model obedience is unverified because of the budget boundary.

## Verification

Focused checks are `nvim --headless -u NONE -i NONE -l tests/targets.lua` and `python tests/test_contracts.py`. The run record distinguishes editor checks, SDK initialization and lifecycle checks from model-backed scenarios that could not be exercised under the required cap.

## License

GNU GPL v3. See [LICENSE](LICENSE). The Python SDK's license does not relicense the bundled Claude Code runtime.
