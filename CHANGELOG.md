# Changelog

All notable changes to deckard are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/). Before 1.0, minor versions may
change the stream format and the Ruby API.

## [0.2.0] - Unreleased

### Changed

- A model's `replicate` block is the plan for dumps rooted at that model,
  and the only plan those dumps consult. `model "Name" do ... end` entries
  inside it say how each class the dump reaches is dumped and matched. A
  reached class's own block is not consulted, so there is nothing to merge
  and no precedence. Classes are named as strings, and an STI subclass
  follows its nearest declared ancestor's entry.
- A record reached only through `belongs_to` carries its row and its own
  dependencies, nothing it owns: the collections its entry names apply to
  the root and to records reached through `has_one` or a planned
  collection. A record dumped first as a dependency and reached later as
  owned, or as a later root, is walked then and written once.
- Natural keys travel in the stream. Each replicant is
  `[type, id, attributes, natural_key]`, the stream version is 2, and a
  load consults no plan on the destination.
- Plans are validated before a dump starts: every named class must be a
  loaded ActiveRecord model and every named association and attribute must
  exist. Problems are reported together as `ConfigurationError`. The
  executable eager loads the application (through Zeitwerk, when present)
  so every `replicate` block has run first.
- `natural_key` and `omit_fields` store attribute names as strings.
- When a natural key matches no destination row and the insert that follows
  fails, `InsertError` names the key that matched nothing.

### Added

- `deckard --plan MODEL [--format text|json]` prints the plan for dumps
  rooted at a model. `ModelConfig#to_h` builds it as data and
  `Deckard::PlanReport` renders it.
- `docs/traversal.md`: how a dump walks the graph, with a worked example.
- `bin/rspec`.

### Removed

- Per-dump options on `dump` (`associations:`, `omit_fields:`,
  `omit_associations:`). `dump(object)` and `dump_replicant(dumper)` are the
  whole API.
- Per-class configuration inheritance. Plans are keyed by root class name.
- `Deckard::UnsupportedAssociation`. A `has_and_belongs_to_many` or
  `has_many :through` association named by a plan is a
  `ConfigurationError` like any other plan problem.

## [0.1.0]

Initial development version: `-r`/`-d`/`-l` executable, versioned Marshal
stream, ActiveRecord dumping with automatic `belongs_to` and `has_one`
traversal, opt-in `has_many`, natural keys, field and association omission,
custom-object protocol, transactional loads.
