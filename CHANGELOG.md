# Changelog

## Sol 6.1 low benchmark candidate

- Add the installable `nvim-claude` Lua module, configurable native keymaps, cursor-local multiline prompts, streaming answer floats, and result reopening.
- Capture UTF-8, linewise, and native virtual-cell block targets with extmarks. Reject stale results, preserve insertion boundaries, and apply completed edits as one undo step.
- Add a private asynchronous Python/SDK installer and framed stdio bridge, without a listening port or separate Claude installation.
- Add runtime model discovery, manual expressions, conservative prompt ceilings, actual compaction, exact saved-session resumption, sticky persistence, and plugin-owned ephemeral cleanup.
- Keep system-prompt overrides session-local and raw assistant history immutable. Normalize punctuation only when explicitly requested.

The candidate remains unmerged. See the README for its branch and the benchmark result record for executed checks and runtime limitations.
