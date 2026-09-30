# Third-party notices

The root MIT license applies to Chillor-authored code, not to third-party components or separately downloaded model weights.

## Vendored source

- MarkdownUI 2.4.1 — https://github.com/gonzalezreal/swift-markdown-ui — MIT; `Vendor/swift-markdown-ui/LICENSE`.
- NetworkImage 6.0.1 — https://github.com/gonzalezreal/NetworkImage — MIT; `Vendor/NetworkImage/LICENSE`.
- swift-cmark 0.4.0 — https://github.com/swiftlang/swift-cmark — notices in `Vendor/swift-cmark/COPYING`.

See `Vendor/README.md` for local manifest modifications.

## Separately installed runtime components

- OpenAI Agents SDK — https://github.com/openai/openai-agents-python. Used for the agent loop, sessions and MCP integration; Chillor is not an OpenAI product.
- CPython and its bundled libraries — retain the license files from the chosen runtime distribution.
- Ollama and its included inference backends — retain all licenses/notices from the chosen runtime distribution.
- Python dependencies listed in `Resources/AgentTools/agent-requirements.lock` — retain their installed distribution metadata and license files when distributing an app.
- Qwen or other model weights — downloaded separately; their licenses are not replaced by Chillor's MIT license.

The build copies runtime distributions with their notices and includes the vendored Swift licenses in the application's ThirdPartyNotices folder. Audit the exact runtime inputs before publishing binary releases.
