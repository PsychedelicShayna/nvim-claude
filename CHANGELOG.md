# Changelog

## Sol 6.1 NeoPi benchmark candidate

- Add cursor-local ask, replacement, and insertion prompts with multiline input, streamed result floats, and cancellation.
- Track captured targets with extmarks and content guards, including UTF-8, linewise selections, blockwise virtual cells, and follow-ups to replacement output.
- Add configurable native mappings and the `NvClaude` command namespace without requiring backend setup at editor startup.
- Provision the latest Python Claude Agent SDK asynchronously into a locked private environment and use its bundled runtime over framed stdio RPC, with named-object parameters and recoverable request errors.
- Add runtime-announced model selection, manual expressions, separate effort/context options, and conservative pre-dispatch context bounds.
- Retain exact SDK sessions on save, support sticky persistence and resumption, compact through the runtime, and clean every registered ephemeral transcript, including rotated SDK session IDs.
- Keep raw assistant history separate from punctuation-normalized presentation and apply session-local system prompt overrides on the next request.

This is an unmerged comparison candidate. The run record distinguishes exercised behavior from platform and runtime limitations.
