# Deckard Agent Guidelines

## Public-repository hygiene

Treat Deckard and its GitHub artifacts as public-facing, even while the
repository is private.

- Never include names, URLs, identifiers, issue or pull-request numbers,
  branches, screenshots, fixtures, domain model names, or provenance from
  non-public downstream repositories.
- Describe downstream integration findings generically, such as “a downstream
  Rails application” or “integration testing.”
- Sanitize GitHub issues, pull requests, release notes, commit messages,
  documentation, examples, and test data before publishing them in Deckard.
- Keep unsanitized investigation notes and artifacts outside the Deckard
  checkout.
- Before publishing changes, search the tracked tree and proposed GitHub text
  for non-public repository references.
