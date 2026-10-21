# Changelog

## Astra 6 medium benchmark candidate

- Add cursor-local prompts, streamed answer floats, configurable native mappings, and captured extmark edits.
- Handle UTF-8, reversed, linewise, and blockwise targets, including partial-tab cells and single-step undo.
- Add asynchronous private SDK provisioning and framed stdio transport.
- Add SDK-backed conversation storage, exact session ownership, cancellation, model discovery, prompt overrides, and punctuation normalization.
- Refuse explicit prompt ceilings because the installed SDK does not establish a hard next-request bound. The benchmark's required ordinary editing under a verified 100k ceiling remains unmet. Model-default operation is an explicit uncapped option, not a substitute for that requirement.
