# Changelog

## Astra NeoPi benchmark candidate

- Add cursor-local ask, replacement, and insertion with extmark-tracked targets, streamed result floats, cancellation, and single-step undo.
- Add configurable mappings and the `NvClaude` command namespace without requiring authentication during setup.
- Provision the official Python SDK asynchronously in a plugin-owned environment.
- Isolate model tools, memory, settings, and MCP; validate edits before touching source text.
- Add runtime model discovery, model expressions, saved and ephemeral conversations, sticky retention, actual compaction, session-local prompt overrides, and presentation-only punctuation normalization.
- Guard fully assembled first-party API requests against a conservative complete-wire byte bound before forwarding. Include compaction and runtime-generated input in admission.
- Deliver this implementation as an unmerged benchmark branch, not a nightly or stable release.
