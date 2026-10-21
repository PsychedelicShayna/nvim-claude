# Changelog

## Astra 6 high NeoPi benchmark candidate

- Add cursor-local prompts, separate answer floats, configurable native mappings and `:NvClaude` commands.
- Track UTF-8 and blockwise targets with extmarks, content checks and one-transaction application.
- Provision a plugin-owned Python environment asynchronously and communicate through framed stdio JSON-RPC.
- Add runtime-announced model selection, manual expressions, conversation manifests, exact-session cleanup and saved-session resume.
- Keep raw model history separate from punctuation normalization and buffer context.
- Refuse numeric hard-budget requests because the inspected runtime has no verified preflight enforcement mechanism. The candidate therefore does not satisfy the specification's ordinary 100k editing acceptance criterion.
- Fix prompt resizing to retain its floating-window coordinate frame. The attached Neovim UI exercise caught the original callback error; the corrected multiline prompt, Escape behavior and focus restoration passed.
- Match the native-selector expression table, validate raw effort choices against runtime metadata and show the local-budget consequence in model-change notifications.
