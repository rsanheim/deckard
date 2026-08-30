# Association coverage audit

*Date:* 2026-08-30
*Method:* two research agents mapped every association type and graph topology to actual
tests; the gap claims were spot-checked with grep, and every behavioral question was then
answered by running a throwaway script against the real gem test database (PostgreSQL 18,
the same `Dumper`/`Loader`/`ActiveRecord` code the specs use). Each "Verified by running:"
line reports what actually happened. The original audit was read-only with 54 green
examples. Follow-up changes are recorded below; the current default suite has 57 green
examples.

Contract context (`docs/spec.md` sections 4 and 13): belongs_to and has_one traverse
automatically; has_many only via explicit `associations` opt-in. Polymorphic belongs_to
must raise `Deckard::UnsupportedAssociation`. Explicitly *not* part of the v1.0 contract
(may work accidentally, no promised behavior): HABTM join-table replication,
`has_many :through`, `has_one :through`, polymorphic associations, complicated STI
dispatch, deferrable dependency cycles.

## Association types

### belongs_to — Covered

We test that dumping a record pulls in its belongs_to parent, that the parent gets a new
destination id, and that the child's foreign key points at that new id
(`spec/deckard/active_record_spec.rb:27-44`). We test that a nil foreign key stays nil
(`active_record_spec.rb:70-78`), and that omitting a belongs_to — by association name or
by foreign-key column — skips the parent and drops the key from the stream
(`spec/deckard/model_api_spec.rb:94-108`). Both optional (`Book`) and required
(`Profile`) associations appear in the fixtures.

We do not have a test for a *required* belongs_to whose foreign key is nil in the source
row. Reading the code, that should just fail the destination's NOT NULL constraint as a
normal load error, but no test says so.

### has_one — Partial

We test that dumping a record automatically includes its has_one child and remaps the
child's foreign key (`active_record_spec.rb:46-54`). A record with *no* has_one child is
only covered indirectly: several tests assert exact `dumper.counts` hashes, which would
fail if a missing child were somehow dumped, but no test targets the absent-child case by
name.

We do not test loading a has_one child into a destination that already has one. No
has_one target model has a `natural_key`, so the update-an-existing-row path is only ever
tested through `Reader`/`ReaderEmail` (`model_api_spec.rb:110-128`), which are reached
via a has_many. It is the same loader code either way, but the has_one shape itself is
untested.

### has_many — Covered for the opt-in path

We test that a has_many named in the `replicate` block is traversed, that all children
arrive with remapped foreign keys (`model_api_spec.rb:28-38`), that a record reachable
both directly and through a configured collection is only written once
(`spec/deckard/edge_cases_spec.rb:64-79`), and that per-dump `associations:` options
apply to classes that have the association and skip classes that don't
(`model_api_spec.rb:70-81`).

We do not test a configured has_many with zero children. Verified by running: it works —
the record dumps alone and loads cleanly. We also do not test dumping the same
ActiveRecord collection twice in one script; the only dumped-twice test uses the
plain-Ruby fixture objects (`spec/deckard/stream_spec.rb:122-133`).

### has_and_belongs_to_many — Covered; fails clearly

The social-app fixture models `Author#bookmarked_posts` as HABTM through the anonymous
`bookmarks` table. Selecting it raises `UnsupportedAssociation` before any records are
emitted and recommends replacing HABTM with an explicit join model
(`spec/deckard/unsupported_associations_spec.rb:8-20`).

### has_many :through — Covered; fails clearly with guidance

The fixture models `Author#commented_posts` through `Author#comments`. Selecting the
far-side association raises `UnsupportedAssociation` before any records are emitted and
specifically recommends replicating `:comments` instead
(`unsupported_associations_spec.rb:22-35`). Dumping the join association remains the
supported pattern: each comment's belongs_to associations pull in its author and post.

### has_one :through — No coverage; happened to work in the common shape

Verified by running: `Supplier -> Account -> AccountHistory` with
`associations :account_history` round-trips completely — but only because `has_one
:account` is traversed automatically anyway, which carries the intermediate row. A shape
whose intermediate association is not an automatic belongs_to/has_one would lose the
linkage the same way has_many :through does.

### Polymorphic belongs_to — Covered, with one wart

We test that a populated polymorphic belongs_to raises `UnsupportedAssociation` with a
clear message (`active_record_spec.rb:114-122`) and that a nil one is left alone
(`active_record_spec.rb:70-78`).

We do not test omitting a *populated* polymorphic belongs_to. Verified by running: the
omission wins over the raise and `billable_id` is dropped — but the `billable_type`
column still streams and loads, so the destination row ends up with a type string
("Author") next to a nil id. The omission should probably drop the type column too.

### Polymorphic has_many / has_one (reverse side) — No coverage; fails clearly

No test model has the reverse side (`has_many :payments, as: :billable`). Verified by
running: opting one in traverses into the child, whose populated polymorphic belongs_to
then raises `UnsupportedAssociation`. So this path cannot silently corrupt anything — it
fails loudly — but no test documents that.

### Self-referential — Covered for chains, not for self-loops

We test a three-level manager chain (`Employee belongs_to :manager, class_name:
"Employee"`) and assert the whole remapped chain survives the round trip
(`edge_cases_spec.rb:48-62`).

We do not test a row that references *itself* (`manager_id == id`). Verified by running:
it raises `Deckard::DumpError` — "dependency cycle detected: Employee(1).manager
references Employee(1)". That is consistent with the emit-order model, but it means a
legitimately self-parented row cannot be dumped at all. Worth deciding whether that is
acceptable v1.0 behavior or a case to support. There is also no self-referential
has_many (`has_many :reports`) in the fixtures.

### STI — Partial

We test that a subclass streams under its actual class name and is referenced that way
(`edge_cases_spec.rb:81-91`), and that `replicate` configuration is inherited by
subclasses without leaking back into the parent (`spec/deckard/model_config_spec.rb:23-38`,
`model_api_spec.rb:53-62`).

We never assert the `type` column's value directly after load — it is proven only
indirectly, because the assertions query through `SpecialLibrary`, whose STI scoping adds
`WHERE type = 'SpecialLibrary'`. "Complicated STI dispatch" is an explicit spec non-goal.

## Identity, remapping, and graph topology

### Source ids differ from destination ids — Covered

The gem specs prove new rows exist at new ids and every foreign key points at the new
parent (`active_record_spec.rb:27-44`). The e2e harness has the stronger proof: it
advances the destination sequences to 100000 before loading
(`harness/script/reset_dest_sequences.rb`) and asserts every loaded id is at least
100000 (`harness/bin/verify:17-18`), so destination ids provably left the source range.

### Primary-key types — Covered

Foreign-key remapping is tested for bigint ids (`active_record_spec.rb:27-44`) and for
database-generated UUIDs (`edge_cases_spec.rb:34-46`). The harness is integer-only.

### Shared child — Covered

One author referenced by two records is written once, and both loaded foreign keys
converge on the single new author (`active_record_spec.rb:56-68`; protocol-level twin at
`stream_spec.rb:105-120`; end-to-end at `harness/bin/verify:29`).

### Empty associations — Work, but untested

A nil belongs_to is tested (`active_record_spec.rb:70-78`). A record with no dependents
at all, and a configured has_many with zero children, have no tests. Verified by
running: both behave correctly — the record dumps alone and loads cleanly. These need
regression tests, not fixes.

### One child / many children — Covered

`active_record_spec.rb:46-54` (one has_one child); `model_api_spec.rb:28-38` (two
has_many children).

### Diamond graphs — Partial

The re-entrant variant is tested: a book whose library's configured collection points
back at the book (`edge_cases_spec.rb:64-79`), which exercises the dumper's in-progress
guard. The classic two-arm diamond — two distinct paths converging on one shared
grandchild — is implied by the shared-child tests but never set up as its own case.

### Self-loop row — Behavior now known, untested

See the self-referential section above: `manager_id == id` raises `DumpError`. A test
should pin whichever behavior we decide is right.

### True dependency cycle — Covered

`CycleA`/`CycleB` referencing each other raises `Deckard::DumpError` mentioning the
cycle (`active_record_spec.rb:124-130`).

### Idempotency — Partial

Dumping the same object twice in one script emits it once (`stream_spec.rb:122-133`).
Natural-key models update the existing destination row instead of duplicating
(`model_api_spec.rb:110-128`) and an ambiguous natural key fails the load
(`model_api_spec.rb:140-150`).

We do not test loading the same stream twice. Verified by running: without a natural
key, a second load inserts a second copy of every row. That matches spec section 10.3 —
deckard never updates or deletes existing rows unless a natural key says to — so it is
correct behavior, but no test asserts it.

### Stream ordering — Partial

Only one test asserts frame order directly (`edge_cases_spec.rb:81-91` — the library
frame precedes the book that references it). Everywhere else, ordering is proven
indirectly: a violation would raise `UnresolvedReference` on load, and that failure mode
has its own test (`stream_spec.rb:166-177`).

## E2E harness topology

The harness graph (Author/Profile/Post/Comment, dumped via `Comment.all`) exercises
belongs_to chains, has_one, shared authors, the sequence-divergence id proof, encryption
re-keying, a PG enum, and a generated column. It does not exercise UUID keys,
self-reference, diamonds, cycles, or natural keys — by design, those live in the
gem-spec tier.

## Proposed follow-ups (for review — none done)

In-contract gaps — behavior verified correct, each needs a small regression test:

- [ ] Zero-dependents record: dump a bare record, assert `counts == {"Type"=>1}` and a clean load
- [ ] Zero-children opted-in has_many (a library with no books)
- [ ] Double-load of a non-natural-key stream: assert the duplicate-rows behavior (spec 10.3)
- [ ] has_one target with a natural key: pre-seed a destination child, assert it is updated in place rather than duplicated
- [ ] Classic two-arm diamond, named as such, asserting single emission of the shared grandchild
- [ ] Same ActiveRecord collection dumped twice in one script emits rows once
- [ ] Self-loop row: pin the verified `DumpError` behavior with a test (or decide to support it and change code)
- [ ] Polymorphic has_many reverse side: one test documenting the verified `UnsupportedAssociation` raise

Verified warts needing a decision (behavior change, not just a test):

- [x] HABTM and far-side `has_many :through` now raise `UnsupportedAssociation` before emitting records. The through-association error names the join association to replicate instead.
- [ ] Omitting a populated polymorphic belongs_to leaves the `*_type` column behind, loading a dangling type next to a nil id. Recommend dropping the type column alongside the foreign key when the omitted association is polymorphic
