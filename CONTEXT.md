# Project context

nvim-claude is a planned Neovim plugin for explicit, cursor-local collaboration with Claude. It replaces the owner's old `inf`-backed inline workflow without turning the editor into a chat sidebar or giving the model file-editing tools.

This is a single-context repository. [README.md](README.md) explains the product; [SPEC.md](SPEC.md) owns the proposed behavior and open decisions. No plugin implementation exists yet. A proposal in the spec is not an owner-approved decision or an instruction to begin implementation.

## Confirmed direction

- Preserve the working interaction: a small prompt float near the cursor, visual replacement or cursor insertion, a model picker, and separate answers for questions.
- The reference implementation in the owner's configuration is `NervGen`, in `lua/usercmds/nervgen.lua`. `<leader>i` invokes generation/replacement; `<leader>I` opens the model picker. The local `config` symlink is private reference material, not a dependency to publish.
- Lua owns the editor interaction. A local Python process hosts the official Claude Agent SDK. Transport is flexible; stdio RPC is the current proposal, not a requirement to implement LSP.
- Setup creates a virtual environment from system Python, installs the latest released SDK with pip, and runs its bundled CLI. No separate Claude Code installation is required. This supersedes the original fixed-version-pinning idea.
- Show runtime-announced models and allow manually entered model slugs.
- Haiku 5.5 with a 100,000-token prompt ceiling is the initial use case. Keep physical model capacity, a local budget, and pricing boundaries distinct.
- Conversation reuse is deliberate and initially ephemeral. Saving and sticky mode provide persistence. Cache expiry is not the same as losing conversation history.
- The model has no tools. Neovim applies completed edit output to the captured target. Ask output does not modify the source buffer.
- Output punctuation normalization must not rewrite the raw assistant history.

## Glossary

| Term | Meaning |
| --- | --- |
| Invocation | An explicit editor action that opens a prompt for an operation. Opening the prompt alone does not send a model request. |
| Operation | One of ask, replace, or generate. It determines where the response goes. |
| Ask | A question answered in a float, optionally grounded in a selection. It leaves the source buffer unchanged. |
| Replace | Transform the captured selection and replace that target only. |
| Generate | Insert new text at a captured empty range. Also called insertion in the UI. |
| Prompt float | The small editor window containing the user's instruction. It is not a permanent sidebar composer. |
| Answer float | A window displaying an ask response or an edit result that could not be applied. |
| Instruction | The user's current request, separate from the document being edited. |
| Source buffer | The Neovim buffer from which a request captured its target and context. It need not be the current buffer when output arrives. |
| Target | The exact selection or insertion boundary belonging to a request. Blockwise selection has multiple row segments. |
| Remembered target | Editor state used to select the same passage on a later invocation, updated after a successful replacement. Not an SDK session. |
| Buffer baseline | The document revision known to have entered the active model context. Diffs are relative to this revision, not simply the last file saved on disk. |
| Snapshot | A complete current buffer representation supplied to the model. |
| Excerpt | An explicitly incomplete piece of document context. Missing regions are unknown, not unchanged. |
| Context diff | An appended change from a named baseline revision to a new revision. It does not rewrite earlier conversation messages. |
| Conversation | The plugin's logical sequence of user instructions and raw assistant replies, with model configuration and retention state. |
| SDK session | The runtime handle and history used to carry a conversation through Claude Code. It is distinct from a Neovim session. |
| Ephemeral conversation | A conversation not retained for later resumption after its lifecycle expires. Whether it may use temporary disk storage remains undecided. |
| Saved conversation | A conversation explicitly retained for resumption, regardless of cache warmth. |
| Sticky mode | Automatic persistence for the active and subsequent conversations, under the spec's proposed transition rules. |
| Prompt cache | Provider-side reuse of computation for an unchanged request prefix. It is not the store of conversation messages. |
| Cache TTL | The provider's lifetime for a cached prefix after a qualifying request. An estimated TTL is not proof of a live entry. |
| Ephemeral expiry | The plugin's decision to start fresh after its cache-aware inactivity interval. It does not delete remote cache entries. |
| Context occupancy | Tokens currently represented in the model context. Not the sum of all tokens ever billed for the conversation. |
| Context limit / local budget | The plugin's requested bound, separate from the model's physical context capacity. A compaction trigger alone does not prove hard enforcement. |
| Compaction | Replacing detailed conversation context with a shorter summary. It is lossy and can itself consume tokens. |
| Runtime model selector | The model ID or native variant selector accepted by Claude Code. A plugin-local budget suffix is removed before passing this value to the SDK. |
| Effort | A model-supported reasoning setting, distinct from model identity and context capacity. |
| Raw output | The assistant text retained in conversation history before presentation changes. |
| Presentation output | The text displayed or inserted after the chosen punctuation mapping. |
| Watermarks command | The draft command name for punctuation normalization. It is not watermark detection and says nothing about who authored text. |
| Python bridge | The plugin-owned Python process translating local editor requests to SDK operations and streaming events back. |
| Bundled CLI | The Claude Code executable distributed with the Python SDK. The Python wrapper's license does not relicense this runtime. |
| Nightly | The integration branch receiving development PRs. Not a canary branch. |
| Master | The stable/default branch, promoted only through a separate PR from nightly. |
| Topic worktree | An isolated checkout for one feature/fix/docs branch based on `origin/nightly` after repository bootstrap. |
| Promotion | The owner's separate decision to merge nightly into master. Finishing a development PR does not authorize promotion. |

## Domain invariants

- The operation and captured target determine edit scope. Model prose and subsequent editor focus do not redefine it.
- Ordinary edits outside a target can move it; changing the target's contents invalidates an outstanding replacement unless it is deliberately reconciled.
- Ask never modifies source text. Failed or canceled requests never apply partial edits.
- The next request describes the actual buffer, including user edits, undo, and output normalization.
- Raw history, current buffer state, saved storage, and provider cache are separate sources of state.
- A full snapshot, a diff, unchanged context, and an excerpt have explicit meanings. Absence of a field is not overloaded to mean several of them.
- Model selection does not silently change billing mode or increase a chosen local budget.
- No model/tool call is needed merely to keep a cache warm.

## Repository workflow

The owner chose NeoPi's development conventions, adapted to this smaller repository:

- GitHub repository and issue tracker: `PsychedelicShayna/nvim-claude`.
- Stable/default branch: `master`. Integration branch: `nightly`.
- Features, fixes, and documentation changes use topic branches in their own worktrees, based on `origin/nightly`.
- Development PRs target nightly. Use merge commits, preserving signed commit provenance; do not squash or rebase.
- Master receives only promotions from nightly. No direct feature or hotfix PR into master. Promotion is a separate owner decision.
- No canary batches for this project.
- Use NeoPi's canonical triage roles alongside its type, priority, effort, and PR-state vocabulary. The owner-approved configuration is in `docs/agents/`; repository-specific workflow is in `docs/policy/README.md`.

This section records the intended workflow, not proof that remote branches or protections already exist. Bootstrap and protection setup must be reported separately from policy documentation.

## Planned implementation comparison

The current assignment establishes the common baseline only. The owner intends to compare complete plugin implementations built independently in separate worktrees, not divide one implementation among agents. Planned candidates include Astra in NeoPi, Astra in Codex CLI, and Sol 6.1; Opus 5.5 is a possible additional candidate. The Astra runs are intended to use extra-high reasoning. This is a plan for later, not authorization to create or launch those runs now.

Assess the specification before calling it a fixed comparison target. Unresolved behavior must either be settled for every run or explicitly left as an implementation choice shared by every run. Do not claim target lock merely because the documents exist.

## Unresolved design

The open-decision section of SPEC.md is authoritative. In particular: the default Normal-mode short action, speed-sensitive mapping behavior, ephemeral disk storage, raw versus structured edit output, and blockwise output representation still need resolution. Runtime probes must establish catalogue discovery, no-tools enforcement, authentication, compaction, strict budget accounting, and prompt replacement before those behaviors are advertised as working.

## Naming

Use **nvim-claude** for this plugin, **Claude Agent SDK** for the official SDK, and **NervGen** for the inspected inline reference. The owner also describes that workflow as NervAgent; it is not the separate conversation panel.

**NeoPi**, repository `neopi`, also called **NPI**, is the owner's OMP-derived harness and the reference for repository workflow. Dictation may spell it "NeoPy"; that refers to NeoPi, not a Python project.

The owner's idea of packaging the NeoPi repository setup as a reusable global skill is parked separately. Applying its conventions here does not authorize creating that skill.
