# Changelog

## 1.2.0

- **History per environment.** The sidebar shows only the active environment's history; *Clear* clears just that one. Requests are filed under the environment they were sent with, even if you switch while one is in flight. Rows show which key was used when the environment has several. History from earlier versions appears under *No Environment*.
- **Keys live in the environment.** Add, switch, rename and delete keys in the environment editor; editing a 🔒 variable edits the key in use, so they never drift to "Unsaved key". The toolbar shows one menu (environment · key) and only lists keys when there are two or more. *Manage Keys…* is gone.
- **New requests show where they'll go.** An empty URL field reads `{{baseUrl}}/path — sending with <environment> · <key>`.
- **Fixed:** the environment menu in the toolbar could overlap the Code button after its label got longer.

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
