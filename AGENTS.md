# Development rules

Read CONTEXT.md before domain work. Read SPEC.md before designing or implementing plugin behavior; it defines the shared behavior and acceptance criteria. Read docs/agents/domain.md when exploring domain terms, invariants, or decisions. Runtime limitations need evidence, not silent scope reductions.

This repository is the common baseline for independent end-to-end implementation comparisons. Implementation must await explicit owner instruction. Preparing documentation does not start a run.

## Repository workflow

Follow the workspace policy where supplied. Repository-specific values and promotion rules live in docs/policy/README.md; read it before creating branches, commits, issues, or PRs.

Use topic worktrees based on origin/nightly. Development PRs target nightly. Master receives only a separate owner-approved promotion from nightly. Use signed commits and merge commits, never squash or rebase. There are no canary batches in this repository. docs/policy/README.md defines delivery, cleanup, and the exception for owner-authorized benchmark branches.

Keep changes small and commit logical units. Preserve the owner's original drafts before revisions. Every commit needs a descriptive body and model attribution; verify its signature before pushing.

Keep the private config symlink and unrelated local scratch files out of commits. Lua owns editor state; Python owns the SDK bridge. Model prompts belong in static resources. Check installed SDK behavior rather than guessing from another SDK's API.

## Agent guidance

Keep agent-facing guidance in root AGENTS.md and CONTEXT.md, and canonical docs/agents files. README.md and SPEC.md remain product documents; docs/policy contains repository policy. Do not create CLAUDE.md, a wayfinder, or a separate ADR directory.

Read docs/agents/issue-tracker.md before tracker operations and docs/agents/triage-labels.md before filing, triaging, claiming, or labeling issues and PRs. Label names do not impose review gates or authorize promotion into master.
