# Changelog

## 1.1.0

- **Named API keys.** Keep several keys for the same API and switch between them from the toolbar, which shows the key in use. Pasting a request with a different key for the same host keeps the existing key instead of overwriting it. Keys can be renamed and deleted in *Manage Keys…*; deleting one removes it from the Keychain.

## 1.0.1

- **Automatic updates.** Wisp checks for new versions in the background and can install them with one click (*Wisp → Check for Updates…*). Updates are signed and verified before installing.

## 1.0.0

First release.

- Native, universal (Apple silicon + Intel) API client for macOS 14+
- Keychain-backed credentials: secrets detected on paste and moved out of plain text
- Host-scoped environments with inherited auth and headers
- OpenAPI/Swagger import, including discovery from documentation pages; Postman, Insomnia, HAR and cURL import
- Schema-aware GraphQL with a visual query builder
- Diagnostics for auth challenges, HTML responses and redirects; response insights
- Pagination, JSON path filters, capture-to-variable
- Code generation for cURL, HTTPie, fetch, Python, Laravel, PHP, Go and Swift; Markdown docs export
