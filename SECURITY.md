# Security

Wisp handles API credentials, so security reports are taken seriously.

## Reporting a vulnerability

Please **don't open a public issue**. Report it privately through GitHub:
**Security → Report a vulnerability** on this repository.

Include what you found, how to reproduce it, and the Wisp version (*Wisp → About Wisp*). You'll get a reply within a few days, and credit in the release notes if you'd like.

## Scope

Especially interesting: anything that could expose secrets (Keychain values, OAuth tokens, credentials scrubbed from history), send credentials to the wrong host, or execute content from an API response.

## Supported versions

Fixes go into the latest release, so please check you're on it before reporting.
