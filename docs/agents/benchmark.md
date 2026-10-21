# Benchmark implementation runs

This branch is the shared launcher for independent implementations of nvim-claude. It is not a plugin implementation or a place to edit one. The owner's instruction **implement** starts exactly one complete run using the model, effort, and harness she selected for that session. No additional explanation from the preceding conversation is needed.

Read root AGENTS.md, CONTEXT.md, SPEC.md, README.md, and docs/policy/README.md before implementation. SPEC.md defines the full product, including portable installation and the common setup/keymap API. This document defines benchmark delivery instead of ordinary nightly integration.

## Candidate identity

The first four runs are:

| Selected model | Harness | Naming stem |
| --- | --- | --- |
| GPT-6 Astra | NeoPi | `astra-6-neopi` |
| GPT-6 Astra | Codex CLI | `astra-6-codex-cli` |
| Sol 6.1 | NeoPi | `sol-6-1-neopi` |
| Sol 6.1 | Codex CLI | `sol-6-1-codex-cli` |

Sol runs use extra-high reasoning. Preserve the operator's selected Astra effort as well. Later candidates may include Opus 5.5 in Claude Code and NeoPi; do not start those or any other run on the owner's behalf.

Determine your actual model and harness from the session's own identity/metadata. These names are not instructions to switch models. Record the actual provider/model identifier and effort, not merely the friendly branch stem. Do not fabricate an identity if your harness genuinely cannot expose it. The owner chooses the model; you choose the matching name from that observed identity.

Add a unique run suffix, such as a UTC timestamp plus a session-ID or generated UUID fragment. The branch is `experimental/benchmark-<stem>-<run>`, and its sibling worktree is `../nvim-claude-wt-<stem>-<run>`. The model and harness must both be recognizable in the path. A collision means choose a fresh suffix, not overwrite or reuse another run.

If already inside your candidate worktree, resume that run from its recorded baseline and identity. Do not create a second candidate merely because the conversation resumed.

## Start from the same baseline

The shared checkout is on branch `benchmark`. Leave its files, branch, and HEAD unchanged. Multiple harnesses may start there at once. Create your candidate worktree before any implementation or run-record edits, then use that worktree explicitly for every file and shell tool.

The pinned nightly seed is `c1cf1e11bb0e9768c4d62a5cfca1a39fc49789e3`, the remote nightly merge of PR #4. The launcher adds only benchmark instructions on top of that seed. This preserves the remote-nightly worktree origin while ensuring every candidate receives the same benchmark-specific documents.

1. In the launcher, record its absolute directory and `git rev-parse HEAD` as the benchmark baseline commit. Confirm the current branch is `benchmark` and the launcher has no tracked modifications that would make its documents differ from that commit. Do not reset or clean another session's files.
2. Fetch origin. Verify the recorded baseline is contained in `origin/benchmark` and the pinned nightly seed is its ancestor. Use the recorded launcher commit, not a moving nightly tip or another candidate's branch. The launcher is frozen for this comparison cohort.
3. Create the unique candidate branch and worktree from the pinned fetched nightly seed, then fast-forward only that candidate to the recorded benchmark baseline. With your resolved absolute worktree path and branch name, the operations are:

   ```sh
   git worktree add "$worktree" -b "$candidate" c1cf1e11bb0e9768c4d62a5cfca1a39fc49789e3
   git -C "$worktree" merge --ff-only "$baseline"
   ```

   `worktree`, `candidate`, and `baseline` are the values you resolved above, not literal placeholder names to retain. Do not merge anything into the launcher, nightly, or master. If the ancestry check fails, report the concrete mismatch instead of mixing baselines.
4. Create `docs/agents/benchmark-result.md` in your candidate. Initially record only observed run identity, effort, harness/version when available, baseline commit, candidate branch, and start time. Commit that real run record before implementation, then keep it current. It is not a passing result until the work is actually complete.
5. File your own run issue with `needs-triage`, `enhancement`, `experiment`, one priority and effort, following docs/agents/issue-tracker.md. Reference the benchmark preparation issue #5 and the baseline spec rather than inventing requirements. Deliberately triage and claim that issue before working; do not claim sibling runs. The owner's word "implement" authorizes this one run.

## Implement the complete plugin

Build every behavior in SPEC.md. The target is a real plugin that installs from `PsychedelicShayna/nvim-claude` at your branch through lazy.nvim on a clean supported Neovim configuration. Commands must register, documented default bindings must work, overrides and disabling must work, and first backend use must provision the plugin's own Python/SDK environment. The Lua entry point and key options are shared across candidates so the owner can switch branches without rewriting her configuration.

Do not use the owner's private config symlink, an existing local implementation, or another candidate's code or design. The common specification already describes the NervGen interaction that matters. Inspecting the official SDK/runtime and its documentation is legitimate implementation research. Keep this run independent.

Implement with the selected model in the selected harness. Do not hand implementation to another model or silently change effort to finish faster. If same-model helpers are used, record them; if the available delegation policy would substitute a different implementation model, work inline. Cheap watchers may monitor checks without contributing implementation. Do not create the other comparison candidates.

Use small signed commits with both descriptive bodies and actual model attribution. Follow the signing instructions in docs/policy/README.md and verify each signature before pushing. Push only your own candidate branch; no force-push or history rewrite after publication. Document product behavior and maintainability decisions where relevant rather than leaving scaffolding, fake backends, or unfinished core paths.

## Verify what the owner will install

Exercise the actual Neovim interaction and the acceptance scenarios in SPEC.md. Use focused, locally runnable checks where they defend consumer-visible behavior. There is no requirement to invent a full CI pipeline for this benchmark. Delegate any long-running check watch and continue independent work within your run; do not idle waiting or pick up unrelated product issues that would expand this benchmark.

Publish the candidate early enough to test installation from its actual GitHub branch with lazy.nvim. A local `dir` plugin entry is not the installation acceptance check. Use a clean, run-specific Neovim config/data/state/cache environment so tests neither depend on nor alter the owner's editor profile or another candidate's state. Do not copy credentials into that environment. After installation, start a fresh Neovim process and check the normal setup path, commands, default/overridden/disabled keys, and asynchronous backend provisioning.

Authentication is a separate boundary, not permission to fake model behavior. Probe the real bundled runtime's credential discovery and supported login path. Do not silently use paid API credentials as a fallback, copy refresh tokens, or claim authenticated behavior without exercising it. If account access is unavailable, deliver the real installation/login path and state precisely which model-backed checks remain unverified. Commands and the editor UI must still load. Record the resolved Python, SDK, and bundled CLI versions; latest-on-setup is required by the product and can vary between runs.

Update README.md with accurate installation instructions for your actual candidate branch and the supported versions you verified. Remove obsolete "specification only" notices once they are no longer true, without claiming unexercised features passed. A runnable installer with missing core implementation is not a completed candidate.

## Deliver a candidate, not a merge

Before declaring delivery:

- Push every intended commit and verify that the remote candidate ref resolves to the delivered local HEAD. Keep private credentials, logs containing secrets, virtual environments, caches, and installed dependencies out of Git.
- Finish `docs/agents/benchmark-result.md` with the exact model/harness/effort, baseline, runtime versions, executed verification and results, remaining limitations, important implementation choices/challenges, and reproducible source line counts. State whether counts include tests or generated files. Compare implementation quality honestly; fewer lines alone do not establish maintainability.
- Provide a copyable lazy.nvim entry naming the actual repository and candidate branch with `main = "nvim-claude"` and `opts = {}`. Explain how to override/disable keys and authenticate if necessary. The owner tests by selecting the branch and restarting Neovim.
- Open a **draft comparison PR targeting `benchmark`**, not nightly or master. Use the repository PR template and labels `enhancement`, `experiment`, one priority, and `needs-review`. Link your own run issue and record that this is an unmerged benchmark candidate awaiting owner selection. A draft PR supplies provenance, not a merge request the agent should complete automatically.
- Record the delivered commit in the PR and final reply, plus the candidate branch, install entry, and any unverified credential-dependent behavior. The run record itself need not contain its own self-referential final commit hash.

Do not merge the candidate PR into benchmark, nightly, or master. Do not enable auto-merge. Do not close sibling runs or select a winner. The roughly 80% ordinary-nightly merge rule does not apply to benchmark candidates. Selection and eventual integration belong to the owner.

The branch is the installable artifact for this Lua/Python plugin. If you produce a separate build/package artifact, retain its exact commit/build identity and publish it as a candidate prerelease rather than a stable release. Do not invent a native binary or add a deployment pipeline just to complete a benchmark.

## Clean up without deleting the benchmark

Stop only processes you started, and remove only your own disposable test environments. Once all intended work is pushed and the remote ref is verified, leave the candidate worktree and return to the recorded launcher path. Remove your candidate worktree and its local branch. Because this candidate is intentionally unmerged, deleting that local branch may require `git branch -D`; this is safe only after verifying its commits remain on the retained remote branch. Never use force-removal to discard uncommitted work.

Retain the remote candidate branch and draft comparison PR for the owner's tests. Keep the shared `benchmark` launcher worktree: it is intentionally persistent for the comparison, not an abandoned task worktree. Do not delete another run's branch, checkout, processes, or cache.

Benchmark mode ends only on the owner's instruction. The selected implementation can later be integrated through the ordinary owner-controlled workflow, restoring normal agent instructions so this benchmark exception does not leak into nightly or master. Losing candidates remain available as benchmark records unless the owner later requests their removal.
