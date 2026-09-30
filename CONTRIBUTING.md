# Contributing

Small, focused issues and pull requests are welcome. Explain the user-visible problem, implementation, and evidence that the change works.

- Preserve local inference as the default. Do not add silent cloud fallback.
- Keep history, tool-call/result pairing, cancellation, and task boundaries intact.
- Preserve text selection, formatting, links, wrapping, complete streaming, and reading position when improving UI speed.
- Use synthetic fixtures. Never commit real conversations, capture images, personal paths, API keys, or test-run databases.
- Run the offline Python checks in README and `swift build -c release` for native changes. Run relevant macOS integration checks when available and state what was not tested.
- Never claim a model benchmark, sandbox guarantee, or successful task solely from a mock test.

Third-party additions must include their upstream source, version, license and rationale. Changes to runtime capabilities, network access, permissions or installers need explicit review.

By contributing, you agree to license your original contributions under the project's MIT license. Third-party code retains its original terms.
