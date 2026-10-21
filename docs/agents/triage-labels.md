# Triage labels

| Canonical role | Tracker label | Meaning |
| --- | --- | --- |
| needs-triage | needs-triage | Maintainer needs to evaluate the issue |
| needs-info | needs-info | Waiting for necessary information |
| ready-for-agent | ready-for-agent | Fully specified and ready for an agent |
| ready-for-human | ready-for-human | Requires human implementation |
| wontfix | wontfix | Will not be actioned |

## Orthogonal house labels

- Type: bug, enhancement, documentation, question.
- Priority: priority: p0, priority: p1, priority: p2, priority: p3.
- Effort: effort: tiny, effort: small, effort: medium, effort: large, effort: very large.
- PR state: needs-review, ready-for-merge, review-stalled.
- baseline: a defect already present on the base branch.
- idea: an undecided possibility, not authorized work.
- spec: an agreed implementation specification, not merely a draft.
- entangled: mutually exclusive alternatives, only when the owner explicitly identifies the cluster.

Every issue and PR has a type, one priority, and a state. Unclassified work uses needs-triage. Issues use the canonical triage roles; PRs use the PR states. Triage does not replace type, priority, or effort. Ready-for-merge does not authorize an agent to promote nightly into master.
