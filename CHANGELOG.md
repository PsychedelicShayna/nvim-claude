# Changelog

## Sol 6.1 high benchmark candidate

- Add the portable `require("nvim-claude").setup()` entry point, native configurable mappings, cursor-local prompt and answer floats, and complete `NvClaude` command namespace.
- Track UTF-8 and virtual-column selections with extmarks, reject stale asynchronous results, and apply complete edits in one undo step.
- Add lazy, locked Python environment provisioning and a Content-Length-framed stdio bridge to the official Claude Agent SDK.
- Enforce a no-model-tools configuration, explicit billing choice, runtime model discovery, validated edit envelopes, and conservative pre-dispatch budget checks.
- Retain exact saved SDK sessions, clean only owned ephemeral transcripts, support native compaction and session-local system-prompt changes, and separate raw history from punctuation-normalized output.

This candidate is intentionally unmerged. Verification and runtime-specific limitations are recorded in `docs/agents/benchmark-result.md`.
