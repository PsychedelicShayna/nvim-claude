# Benchmark mode

Read CONTEXT.md before domain work. Read SPEC.md before designing or implementing plugin behavior; it defines the shared behavior and acceptance criteria. Read docs/agents/domain.md when exploring domain terms, invariants, or decisions. Runtime limitations need evidence, not silent scope reductions.

When the owner says **implement**, build one complete, independent candidate using this session's selected model and harness. Before creating a branch or editing anything, read [docs/agents/benchmark.md](docs/agents/benchmark.md). That instruction is the explicit start signal; do not ask the owner to repeat the spec or choose a worktree name.

The `benchmark` checkout is a shared launcher. Never implement in it. Create your own model-and-harness-named worktree using the pinned-baseline procedure. Deliver a pushed, lazy.nvim-installable candidate branch and a draft comparison PR. **Do not merge candidates into benchmark, nightly, or master.** Retain the remote candidate branch; clean up your local worktree after delivery. Do not start other models' runs.

## Repository workflow

Follow the workspace policy where supplied. Repository-specific values and promotion rules live in docs/policy/README.md; read it before creating branches, commits, issues, or PRs.

For this benchmark, docs/agents/benchmark.md defines the pinned remote-nightly seed, shared launcher baseline, worktree naming, unmerged branch delivery, and cleanup exception. The ordinary nightly merge workflow in docs/policy/README.md remains applicable only to non-benchmark work. Use signed commits and preserve provenance; owner selection is required before any candidate integration.

Keep changes small and commit logical units. Preserve the owner's original drafts before revisions. Every commit needs a descriptive body and model attribution; verify its signature before pushing.

Keep the private config symlink and unrelated local scratch files out of commits. Lua owns editor state; Python owns the SDK bridge. Model prompts belong in static resources. Check installed SDK behavior rather than guessing from another SDK's API.

## Agent guidance

Keep agent-facing guidance in root AGENTS.md and CONTEXT.md, and canonical docs/agents files. README.md and SPEC.md remain product documents; docs/policy contains repository policy. Do not create CLAUDE.md, a wayfinder, or a separate ADR directory.

Read docs/agents/issue-tracker.md before tracker operations and docs/agents/triage-labels.md before filing, triaging, claiming, or labeling issues and PRs. Label names do not impose review gates or authorize promotion into master.
