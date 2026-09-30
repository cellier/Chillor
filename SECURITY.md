# Security

Chillor is an experimental desktop agent. Do not use it as an audited sandbox for hostile code or grant it access to sensitive data without understanding the tool boundary.

- Workspace tools validate relative paths and reject traversal. Network tools restrict private network destinations. These controls need ongoing review.
- Python execution uses macOS Seatbelt profiles, resource/time limits, a separate run directory, and a startup probe. The tool must remain unavailable when the probe fails. A finite probe is not proof against every escape; system-file reads are broader than task-file reads.
- Web content, documents, and tool results are untrusted input. Prompt injection and incorrect model choices remain possible.
- Desktop actions act with the user's macOS permissions.
- Local history and artifacts are not separately encrypted by Chillor. Use the operating system's account and disk protections.
- Optional cloud inference sends selected context to the chosen provider. API keys belong in Keychain, never in issues or source.

For a suspected vulnerability, use GitHub's private vulnerability reporting if enabled on this repository. Otherwise contact the maintainer via their GitHub profile to arrange a private channel. Do not post credentials, private documents, or exploit details in a public issue. Private reporting is not guaranteed to be enabled until repository settings are configured.
