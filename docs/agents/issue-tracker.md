# Issue tracker: GitHub

Track issues and engineering tickets in `PsychedelicShayna/nvim-claude`. Use `gh` from this clone, or pass `--repo PsychedelicShayna/nvim-claude` explicitly. README.md and SPEC.md remain the project overview and shared implementation baseline, not an automatically published issue backlog.

## Filing and operations

1. Read existing issues before filing. If an issue already owns the subject, add the authorized clarification as a comment rather than filing a duplicate. Preserve published provenance; edit an existing body only when the owner authorizes it.
2. Create with `gh issue create --repo PsychedelicShayna/nvim-claude --title "..." --body-file <path> --label needs-triage`. Add known type and sizing labels with additional `--label` arguments. Every new issue starts with `needs-triage`, including a fully written spec.
3. Read with `gh issue view <number> --comments`, including labels. List with `gh issue list --state open --json number,title,body,labels,comments` and relevant filters.
4. Evaluate and assign labels using [triage labels](triage-labels.md). Add `triage: started` during evaluation. Once triaged, every issue needs an appropriate type, exactly one priority, and exactly one effort label. Use `gh issue edit <number> --add-label "..."` or `--remove-label "..."` to reflect the result.
5. Close only after the requested work merged, a verified duplicate is identified, or the owner authorizes closure. Explain why. `Fixes #<n>` references do not necessarily auto-close issues when merging into a non-default branch.

Always pass `--label needs-triage` at filing time. [.github/workflows/issue-triage.yml](../../.github/workflows/issue-triage.yml) adds that label to new issues without checking out or executing repository or issue-supplied code. GitHub runs its `issues: opened` trigger only after the workflow reaches the default branch, and the label is added asynchronously after issue creation. Shipping this file on `nightly` or `benchmark` does not activate it. Until the owner promotes it to `master`, explicit labeling by the filer is the active mechanism.

Every agent-posted issue or comment begins with this identity block, using the actual model name:

```markdown
> [!NOTE]
> <Model Name> on behalf of PsychedelicShayna
```

Review and queue labels describe status, not permission. Claim only ready, authorized work; a finished agent or human part does not mean the PR is mergeable. Ordinary agent-owned PRs merge into `nightly` at roughly 80% confidence under [repository policy](../policy/README.md). Checks and reviews are advisory. Delegate watching to a cheap poller and advance the next ready, authorized task instead of waiting idly. This project uses no canaries. Only the owner promotes `nightly` to `master`.

## Provenance

For work originating in the owner's explanation, put the structured summary first, then preserve relevant messages verbatim under `## Owner's words (verbatim)`, one `<details>` block per message. For speech, preserve the dictation without cleaning it up. Keep corrections and undecided possibilities distinguishable. The owner's words take precedence over the summary. Include the words in the issue itself rather than making a private local path the only source.

## Request meanings

"Publish to the issue tracker" means create a GitHub issue. "Fetch the relevant ticket" means read its body, comments, and labels. Capturing an idea does not authorize implementing it.

## Pull requests as a triage surface

PRs as a request surface: no.

