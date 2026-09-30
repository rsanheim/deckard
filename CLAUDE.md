# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Deckard is a Ruby gem that streams ActiveRecord objects between Rails environments — a modern
resurrection of the `replicate` gem targeting ActiveRecord 8+ and PostgreSQL. Typical use: pipe
production records into a local dev database over SSH.

**`docs/spec.md` is the authoritative v1.0 specification.** Read it before implementing anything. It defines
the API, stream format, correctness invariants (section 17), acceptance criteria (section 18), implementation
order (section 19), and — critically — long lists of explicit non-goals. Do not add features, options,
adapters, or abstractions the spec excludes.

## Commands

```bash
bin/setup                 # install dependencies
bundle exec rake          # default task: specs + standard (lint) + ratchet
bundle exec rake spec     # tests only
bundle exec rake e2e      # end-to-end stream test inside docker compose
bin/rspec spec/deckard_spec.rb                  # one spec file
bin/rspec spec/deckard_spec.rb:12               # one example by line
bundle exec standardrb    # lint (standardrb --fix to autocorrect)
bin/console               # IRB with the gem loaded
bundle exec rake db:migrate   # migrate the test databases and regenerate spec/db/schema.rb
bundle exec rake db:reset     # drop, create, migrate, and seed the test databases
```

## CI

See [AGENTS.md](AGENTS.md#ci-and-validation) for CI coverage and validation
commands. The Crow workflow in `.crow/ruby.yaml` runs `bundle exec rake`
(specs, Standard lint, and the style ratchet) on PRs, default-branch pushes,
and manual triggers. It uses Ruby 4.0.6 and PostgreSQL 18.6. E2E and performance
tests are separate tasks; a green CI result does not cover them.

## Test tiers

Two tiers with a hard boundary:

- Unit/integration (`spec/`): a normal gem suite, runs on the host via `bundle exec rake`.
  The ActiveRecord specs use a real local PostgreSQL 18 and fail when no server is
  reachable. The schema is a small forum (authors, posts, threaded comments, tags,
  reactions, attachments, and so on) whose ordinary features carry every shape deckard
  must handle. It is managed with ActiveRecord's own machinery, configured in
  `spec/support/database.rb`: connection settings in `spec/db/database.yml` (override
  with `DECKARD_TEST_DATABASE_URL` and `DECKARD_TEST_DESTINATION_DATABASE_URL`), one
  migration in `spec/db/migrate`, the generated `spec/db/schema.rb` the specs load, and
  realistic seed data in `spec/db/seeds.rb`. Models live in `spec/support/forum_models.rb`.
  Change the schema by editing the migration and running `rake db:reset`, then commit
  the regenerated schema.rb.
- E2E / full-stack (`harness/`): a real Rails 8.1 app streamed between two containers,
  entirely inside docker compose — source app + source PostgreSQL, destination app +
  destination PostgreSQL, no ports exposed to the host. Run with `bundle exec rake e2e`
  (wraps `harness/bin/stream_test`). New capabilities land with unit/integration specs;
  the e2e test proves the real pipeline (`bin/dump | bin/load`) still works.

The tiers must not intertwine: the gem suite never depends on compose containers, and
the harness never runs the gem's rspec suite — it exercises the gem only the way an
operator would, through real apps and a real pipe.

## Architecture (from the spec)

The operating model is a Unix pipeline: dump on the source (`deckard -r ./config/environment -d "User.find(1)"`),
stream versioned Marshal frames over stdout, load on the destination (`deckard -r ./config/environment -l`)
inside one transaction that commits only after a valid end marker. Primary keys are remapped: the destination
generates new IDs and foreign keys are rewritten via a source-to-destination ID map.

Internal structure (spec section 16) — a few small classes, no adapter frameworks or registries:

- `Deckard::CLI` — parse `-r`/`-d`/`-l`/`--plan`, reserve stdout for the stream, boot the app, wire stdin/stdout
- `Deckard::Dumper` — dedupe by `[type, source_id]`, call `dump_replicant`, write frames
- `Deckard::Loader` — read frames incrementally, resolve `[:id, "User", 1234]` reference tuples, call `load_replicant`, manage the transaction
- `Deckard::ModelConfig` — a root model's plan, backing the `replicate do ... end` DSL: what a dump carries and how each reached class is matched (`docs/traversal.md`)
- `Deckard::PlanReport` — renders a plan's data as text or JSON for `--plan`
- `Deckard::ActiveRecord` — the mixin included into ActiveRecord::Base. Models gain only `replicate`, `dump_replicant`, and `load_replicant`; everything else stays in plain objects:
  - `Deckard::ActiveRecord::Dump` (lib/deckard/active_record/dump.rb) — traversal: belongs_to and has_one automatic, has_many opt-in, foreign-key re-encoding
  - `Deckard::ActiveRecord::Load` (lib/deckard/active_record/load.rb) — callback/validation-free inserts via PostgreSQL `RETURNING`, or natural-key matched updates
- `Deckard::Status` — counts by type on stderr; stdout carries only the stream

Key design constraints to preserve:

- Streaming: neither side materializes the full object graph; memory grows only with the identity set and ID map.
- The custom-object protocol (`dump_replicant` / `load_replicant`) is the core; ActiveRecord support is an implementation of it, not a special case.
- Unsupported cases (composite PKs, unsupported join associations, dependency cycles) raise specific errors from the small `Deckard::Error` hierarchy rather than being approximated.
- The stream is trusted Ruby `Marshal` — an operator tool over SSH, never a public import format.
