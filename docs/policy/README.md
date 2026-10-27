# Repository policy

Use the workspace policy when it is supplied. This file records the owner's repository-specific choices, adapted from NeoPi. It does not authorize bypassing workspace restrictions.

## Branches and worktrees

| Role | Branch | Changes arrive through |
| --- | --- | --- |
| Stable/default | `master` | A separate promotion PR from `nightly` |
| Integration | `nightly` | Topic-branch PRs |

Create each topic branch in its own worktree from the fetched remote integration branch:

```sh
git fetch origin
git worktree add ../nvim-claude-wt-<slug> -b <type>/<slug> origin/nightly
```

Use `feat/`, `fix/`, `docs/`, `test/`, `refactor/`, `chore/`, `ci/`, or `experimental/` according to the work. The owner's stricter promotion rule applies here: master receives only nightly, including urgent fixes. Do not use direct-to-master hotfix PRs.

Keep local base branches aligned with their remote counterparts. Never discard uncommitted user work while synchronizing them. Resolve actual topic/base conflicts by merging the base into the topic, never by rebasing. Do not refresh branches merely because the base moved.

## Commits and pull requests

- Commit small logical changes frequently. Preserve original owner drafts before editorial revisions.
- Use Conventional Commits, with a subject no longer than 72 characters, a prose body explaining what changed and why, and the verification actually performed.
- Include `Model: <provider>/<model-id>` and `Co-authored-by: <Model Name> <noreply@<provider-domain>>` on agent commits.
- Select the supplied agent signing key explicitly for each commit. On the owner's workstation: `git commit -S/home/shayna/.ssh/id_ed25519_github_signing_agents.pub -m "..." -m "..."`. Verify with `git verify-commit HEAD`; never disable signing or change repository signing configuration.
- Use one issue and PR per coherent change, not one PR per small commit. Fill `.github/PULL_REQUEST_TEMPLATE.md` with observed results and reasons for skipped checks.
- Push only the topic branch. Review fixes are new commits after pushing, not amendments or force-pushes.
- Merge commits only. Use `Merge PR #<number>: <conventional PR subject> (@<author>)` as the merge subject. No squash or rebase merging.
- After a PR merges, ensure all intended work is pushed and retained in merged history. Check for uncommitted or unrelated user changes before cleanup; preserve them rather than deleting them. Leave the topic worktree, remove it, then delete its merged local and remote topic branches. Git's merged history and PR refs permit recovery; worktrees are not archives. Owner-authorized retained benchmark remote branches are the exception described below.

## Nightly and promotion

Authoring agents merge their own development PRs into nightly at roughly 80% confidence. Record confidence and relevant failing or skipped checks in the merge note. CI and optional review bots are advisory, not merge gates. The owner tests the integration result.

The integrator does not idle, wait for checks, or poll review status. Delegate watching to a cheap poller and advance the next ready, owner-authorized work. A watcher reports results for any needed follow-up; it does not hold up nightly delivery.

Promotion from nightly into master is a separate owner decision. Agents do not merge that PR. Do not schedule automatic promotions or treat a successful development PR, label, or check as permission to promote.

This project has no canary batches. Documentation-only changes need no routine CI, build, installation, or runtime test. Use focused verification appropriate to the behavior changed. Once plugin code exists, verify changed editor behavior in Neovim and document how the owner uses the nightly version. Do not borrow NeoPi's binary build/install commands for this Lua/Python project.

## Comparison branches

The `experimental/benchmark-*` and `experimental/round-1-*` branches on GitHub are records of an earlier model comparison built against a stricter draft spec. Keep them; do not merge them. The plugin on nightly is built from the current SPEC.md through ordinary topic-branch PRs.

## Release cadence

The owner requested a prerelease with assets for each ordinary, unique successful nightly build. Identify each release's exact commit and build ID, and record the SDK versions used. Do not publish duplicate releases for the same build.

An owner-approved merge from nightly into master triggers stable packaging, tagging, and release automation when code ships. This is release automation after the owner's promotion decision, never automatic stable promotion.

If a GitHub asset upload fails, retain the successful build and its metadata, then retry publishing that build without stalling development or rebuilding merely to retry the upload.

Release automation does not exist yet. The cadence above records the intended behavior; it does not claim that packaging, tagging, or uploads exist.

## Reviews and verification

Review bots are advisory, not gates. Request at most one scoped round for a change with a large blast radius; no round by default. This repository does not assume NeoPi's installed GitHub bots are available here. Every agent-authored GitHub comment, including a review request, uses the workspace identity block.

Only execute contributor PR code locally when the workspace's owner-head criteria are satisfied. Otherwise use trusted CI or a credential-free isolated environment. Use focused verification and preserve the workstation's shared build/test resource limits.

User-facing behavior changes update the relevant docs and changelog. Do not create passing placeholder tests or claim implementation verification for documentation-only work.

## Labels and provenance

`docs/agents/triage-labels.md` defines the vocabulary. Every issue and PR has a type, one priority, and a state. Effort and readiness are separate axes. `docs/agents/issue-tracker.md` defines tracker operations and preservation of the owner's words.

## Branch protection

The owner enabled Standard Protection. The owner's successful response records ruleset ID `25543973` with active enforcement:

- Include the default branch, master, and `refs/heads/nightly`.
- Require a pull request and allow merge commits only.
- Require zero approving reviews; do not add a code-owner, last-push, or resolved-thread gate.
- Block non-fast-forward updates and branch deletion, with no bypass actors.
- Preserve the reference rule's extra approval requirement for unattributed changes where GitHub exposes it.

Workspace policy reserves ruleset/protection changes to the owner. A normal PR requirement does not itself restrict master PRs to a nightly head; the nightly-only promotion rule must also be respected when selecting and merging PRs.

[branch-protection.json](branch-protection.json) retains the setup payload for audit. It is not a pending handoff or an instruction to POST another ruleset.
