# Markdown rendering dependencies

Pinned upstream sources included for reproducible, offline local builds:

- swift-markdown-ui 2.4.1 — https://github.com/gonzalezreal/swift-markdown-ui/tree/2.4.1 (MIT). Source files and LICENSE retained; documentation and upstream test fixtures excluded. Package manifest uses the local dependencies below and excludes upstream tests.
- NetworkImage 6.0.1 — https://github.com/gonzalezreal/NetworkImage/tree/6.0.1 (MIT).
- swift-cmark 0.4.0 — https://github.com/swiftlang/swift-cmark/tree/0.4.0 (licenses in COPYING).

Rendering remains native SwiftUI. Chillor overrides image providers to display local images and explicit links instead of automatically fetching remote images.
