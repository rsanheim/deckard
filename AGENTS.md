# Deckard Agent Guidelines

## CI and validation

- [`.crow/ruby.yaml`](.crow/ruby.yaml) runs on pull requests, default-branch
  pushes, and manual triggers using Ruby and an isolated PostgreSQL service.
  Keep runtime version numbers in configuration rather than documentation.
- CI runs `bundle exec rake`: RSpec unit/integration tests, Standard lint, and
  the style ratchet (`bin/ratchet`). Gems and lint caches live under
  `/cache/deckard/`.
- [`.crow/e2e.yaml`](.crow/e2e.yaml) runs the end-to-end stream test on the
  same events: `harness/bin/stream_test --no-compose`, with both apps in one
  step and a PostgreSQL service for each side.
- The performance suite (`bundle exec rake perf`) is a separate task and is
  not included in CI.
- Validate workflow edits with `crow lint --strict .crow/`. Check the pushed
  commit with `crow-watch --timeout 5m` and require a successful PR pipeline
  before merging. For failures, use the log command printed by `crow-watch`.

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
