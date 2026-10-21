# Triage labels

Use this guide when filing, triaging, claiming, or labeling issues and PRs. The inventory preserves all 67 NeoPi label names and descriptions from the 2026-10-21 snapshot. Specialized labels remain documented even where they have no current use in this repository. Descriptions are copied verbatim; the rules below govern their use here.

## Filing and triage

Every new issue starts with `needs-triage`. Pass `--label needs-triage` explicitly when creating it, even if automation may later add that label. Filing a detailed specification does not skip triage.

During evaluation, add `triage: started`; labels remain provisional. Deliberate triage may then remove `needs-triage` and `triage: started` and set the appropriate readiness or disposition. Use `needs-info` when named information is missing, `ready-for-agent` for specified, authorized agent work, or `ready-for-human` for human implementation. An undecided idea remains an idea, not ready work.

Every triaged issue has an appropriate type, exactly one `priority:*`, and exactly one `effort:*`. Every PR has a type, a priority, and a state. Readiness, queue claims, and review labels are separate from type and sizing. Preserve labels that still describe the issue rather than replacing one axis with another.

Difficulty estimates implementation difficulty. Effort estimates the work for a competent AI agent with a plan. Frame records the time-frame unit with the source's "agent estimates lowered one unit" semantics. These are distinct axes, not interchangeable scales. The source does not specify inclusive numeric bucket boundaries or a complete frame-conversion algorithm. Classify conservatively using the descriptions and record uncertainty in the issue rationale rather than inventing thresholds or timing rules.

Use `entangled` only when the owner explicitly identifies incompatible alternatives. Use specialized upstream and downstream labels only when their descriptions fit the actual work. Their presence in this inventory does not create a dependency or authorize new work.

## Claims and review

Use the agent or human queue labels for the corresponding part of authorized work. Pending means available, started means claimed, and finished means that participant's part is complete. Respect an existing claim. Completion does not establish mergeability, and readiness labels do not authorize implementation of an undecided proposal.

Review labels record requests and findings. They are advisory, not merge gates. In particular, the copied `sentinel-review-requested` description is historical metadata, not a requirement to run a sentinel panel here. Request at most one optional bot round, only for a large-blast-radius change, with a scoped prompt. Address material findings without waiting idly for checks or reviews; delegate watching to a cheap poller and continue ready, authorized work.

At roughly 80% confidence, agents merge their own ordinary PRs into `nightly` under [repository policy](../policy/README.md). Checks and reviews are advisory. This project has no canaries. Neither `ready-for-merge`, `mergeable`, nor any copied reference to an owner merge authorizes promotion to `master`; only the owner promotes `nightly` to `master`. The separately authorized benchmark candidate branches are deliverables, not merge requests, and remain remote as the explicit exception to ephemeral branch cleanup.

## NeoPi label inventory

Each source label appears once below with its original description.

### Type, assistance, and disposition

| Label | Original description |
| --- | --- |
| `bug` | Something isn't working |
| `documentation` | User- or agent-facing docs, README or changelog |
| `enhancement` | New feature or request |
| `question` | Further information is requested |
| `accessibility` | Barrier affecting people with disabilities |
| `good first issue` | Good for newcomers |
| `help wanted` | Extra attention is needed |
| `duplicate` | Same request as another issue; context merged into the canonical one |
| `invalid` | Closed: wrong repo, missing required information or format, or policy violation |
| `wontfix` | Closed: will not be worked on |

### Priority

| Label | Original description |
| --- | --- |
| `priority: p0` | Blocks current work or handles an active incident |
| `priority: p1` | High value or prerequisite for several issues |
| `priority: p2` | Useful planned work |
| `priority: p3` | Backlog or opportunistic work |

### Effort

| Label | Original description |
| --- | --- |
| `effort: tiny` | Under 2 hours for a competent AI agent with a plan |
| `effort: small` | Roughly 2–6 hours for a competent AI agent with a plan |
| `effort: medium` | Roughly 1–2 days for a competent AI agent with a plan |
| `effort: large` | Roughly 3–7 days for a competent AI agent with a plan |
| `effort: very large` | Multi-week or cross-cutting architectural work |

### Difficulty

| Label | Original description |
| --- | --- |
| `difficulty: 0.000-0.125` | Estimated implementation difficulty in 0.000-0.125. |
| `difficulty: 0.125-0.250` | Estimated implementation difficulty in 0.125-0.250. |
| `difficulty: 0.250-0.375` | Estimated implementation difficulty in 0.250-0.375. |
| `difficulty: 0.375-0.500` | Estimated implementation difficulty in 0.375-0.500. |
| `difficulty: 0.500-0.625` | Estimated implementation difficulty in 0.500-0.625. |
| `difficulty: 0.625-0.750` | Estimated implementation difficulty in 0.625-0.750. |
| `difficulty: 0.750-0.875` | Estimated implementation difficulty in 0.750-0.875. |
| `difficulty: 0.875-1.000` | Estimated implementation difficulty in 0.875-1.000. |

### Time frame

| Label | Original description |
| --- | --- |
| `frame: hours` | Estimated time frame: hours (agent estimates lowered one unit) |
| `frame: days` | Estimated time frame: days (agent estimates lowered one unit) |
| `frame: weeks` | Estimated time frame: weeks (agent estimates lowered one unit) |
| `frame: months` | Estimated time frame: months (agent estimates lowered one unit) |
| `frame: years` | Estimated time frame: years (agent estimates lowered one unit) |

### Triage and readiness

| Label | Original description |
| --- | --- |
| `needs-triage` | Not yet triaged |
| `triage: started` | Triage in progress; labels are provisional |
| `needs-info` | Cannot proceed until the named information arrives |
| `ready-for-agent` | Fully specified and ready for an AFK agent |
| `ready-for-human` | Requires human implementation |

### Agent and human queues

| Label | Original description |
| --- | --- |
| `agent: pending` | Ready for an out-of-the-loop (OTL) agent to pick up |
| `agent: started` | An agent has claimed this; do not duplicate the work |
| `agent: finished` | The agent's part is done; not necessarily mergeable |
| `human: pending` | Needs an in-the-loop (ITL) session with a human |
| `human: started` | A human has claimed the in-the-loop part |
| `human: finished` | The human's in-the-loop part is done |

### Review lifecycle and merge status

| Label | Original description |
| --- | --- |
| `needs-review` | Awaiting automated and maintainer review |
| `ready-for-merge` | Review complete; ready for owner merge |
| `codex-review` | Request Codex bot review on the PR for this issue |
| `sentinel-review-requested` | Mandatory sentinel panel review requested |
| `review: codex` | Codex reviews this change (mention @codex) |
| `review: open (codex)` | Codex findings are unanswered on the current head |
| `review: requested (codex)` | A Codex round is requested on the current head |
| `review: closed (codex)` | Codex's latest round on the current head is clean and every finding answered |
| `review: stalled (codex)` | Review loop ended with findings unresolved; summary posted |
| `mergeable` | Meets this repository's documented merge criteria; who merges is policy |

### Specification, alternatives, and existing work

| Label | Original description |
| --- | --- |
| `idea` | An undecided possibility; not a spec, not authorized work |
| `spec` | The issue is or contains an agreed implementation specification. |
| `entangled` | Incompatible alternatives; the owner chooses one, the rest close |
| `experiment` | Tried on an experimental/ branch; never merged to nightly or default without an owner decision |
| `baseline` | Pre-existing defect found during review |
| `stale: similar` | Implemented on nightly, but differently from this spec; open for the remaining differences |
| `stale: identical` | Already implemented on nightly (often via upstream) essentially as specified |

### Upstream, downstream, and targeted fixes

| Label | Original description |
| --- | --- |
| `upstream` | Upstream is involved: sync, compatibility, conflict avoidance or divergence |
| `upstream-sync` | Synchronize changes from upstream |
| `downstream` | Needed by a project that consumes NeoPi |
| `rpc` | Changes or depends on the RPC surface (npi --mode rpc / rpc-ui) |
| `t3c-npi` | Needed by PsychedelicShayna/t3code-npi (NeoPi/OMP provider in T3 Code) |
| `npi-deck` | Needed by PsychedelicShayna/npi-deck (NeoPi web cockpit / fleet console) |
| `hotfix` | Urgent targeted fix |

## Historical local label

`review-stalled` is a retained local label, separate from the 67-label NeoPi inventory. It records a stalled review. Preserve existing uses rather than deleting the label or treating it as an additional review gate. It is distinct from NeoPi's `review: stalled (codex)`.
