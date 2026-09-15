# Deckard Agent Guidelines

## CI and validation

- `.crow/ruby.yaml` runs on pull requests, default-branch pushes, and manual
  triggers using Ruby 4.0.6 and an isolated PostgreSQL 18.6 service.
- CI runs `bundle exec rake`: RSpec unit/integration tests, Standard lint, and
  the style ratchet (`bin/ratchet`). Gems and lint caches live under
  `/cache/deckard/`.
- The Docker end-to-end harness (`bundle exec rake e2e`) and performance suite
  (`bundle exec rake perf`) are separate tasks and are not included in CI.
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
