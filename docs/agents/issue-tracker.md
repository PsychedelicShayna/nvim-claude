# Issue tracker: GitHub

Track issues and engineering tickets in PsychedelicShayna/nvim-claude. Use gh from this clone, or pass --repo PsychedelicShayna/nvim-claude explicitly. README.md and SPEC.md remain the project overview and design draft, not an automatically published issue backlog.

## Operations

- Create: gh issue create --title "..." --body-file <path> --label <labels>.
- Read: gh issue view <number> --comments, including labels.
- List: gh issue list --state open --json number,title,body,labels,comments with relevant filters.
- Label: gh issue edit <number> --add-label "..." or --remove-label "...".
- Close only after the requested work merged, a verified duplicate is identified, or the owner authorizes closure. Explain why. Fixes references do not necessarily auto-close issues when merging into a non-default branch.

Every agent-authored issue or comment begins with the workspace comment-identity block. Include type, priority, and state labels. Use the separate effort vocabulary for implementation sizing; readiness does not replace these labels.

## Provenance

For work originating in the owner's explanation, put the structured summary first, then preserve relevant messages verbatim under "Owner's words (verbatim)", one details block per message. Keep corrections and undecided possibilities distinguishable. The owner's words take precedence over the summary. Do not make a private local path the only source.

## Skill meanings

"Publish to the issue tracker" means create a GitHub issue. "Fetch the relevant ticket" means read its body, comments, and labels. Capturing an idea does not authorize implementing it.

## Pull requests as a triage surface

PRs as a request surface: no.

## Wayfinding

When using a wayfinding workflow, use a map issue and linked child issues. Prefer native sub-issues and issue dependencies; otherwise use a task list, Part of #N, and Blocked by: #N references. Do not invent extra issues or labels merely because this workflow is available.
