# Development rules

Read CONTEXT.md before domain work. Read SPEC.md before designing or implementing plugin behavior; it separates owner requirements, proposals, and open decisions. Do not treat proposals as implementation authorization.

## Repository workflow

Follow the workspace policy where supplied. Repository-specific values and promotion rules live in docs/policy/README.md; read it before creating branches, commits, issues, or PRs.

Use topic worktrees based on origin/nightly. Development PRs target nightly. Master receives only a separate owner-approved promotion from nightly. Use signed commits and merge commits, never squash or rebase. There are no canary batches in this repository.

Keep changes small and commit each added or modified file during this initial setup. Preserve the owner's original drafts before revisions. Every commit needs a descriptive body and model attribution; verify its signature before pushing.

Keep the private config symlink and unrelated local scratch files out of commits. Lua owns editor state; Python owns the SDK bridge. Model prompts belong in static resources. Check installed SDK behavior rather than guessing from another SDK's API.

## Agent skills

### Issue tracker

Issues and engineering tickets live in PsychedelicShayna/nvim-claude GitHub Issues. Read docs/agents/issue-tracker.md before tracker operations.

### Triage labels

Use NeoPi's canonical triage roles alongside type, priority, effort, and PR-state labels. Read docs/agents/triage-labels.md before labeling issues or PRs.

### Domain docs

Use one root CONTEXT.md and docs/adr/ for this single-context project. Read docs/agents/domain.md before domain exploration.
