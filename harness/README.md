# End-to-end harness

A real Rails application, streamed between two docker compose containers the
way an operator would use deckard: a source app with its own PostgreSQL dumps
through `bin/dump`, a destination app with its own PostgreSQL loads through
`bin/load`, and `bin/verify` checks the result. No ports reach the host.

Run it from the repository root:

```bash
bundle exec rake e2e
```

The harness never runs the gem's RSpec suite, and the gem suite never depends
on these containers.
