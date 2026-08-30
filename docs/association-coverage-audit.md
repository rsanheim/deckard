# Association coverage audit

*Date:* 2026-08-30
*Method:* two research agents mapped every association type and graph topology to actual
tests (file:line evidence below); the load-bearing gap claims were spot-checked with grep,
and every behavioral hypothesis was then verified by running a throwaway script against the
real gem test database (PostgreSQL 18, the same `Dumper`/`Loader`/`ActiveRecord` code the
specs use). Each "Verified:" line below reports what actually happened when run. The full
default suite was green before and after (54 examples). No lib or spec code was changed.

Contract context (`docs/spec.md` section 13/4): belongs_to and has_one traverse
automatically; has_many only via explicit `associations` opt-in. Polymorphic belongs_to
must raise `Deckard::UnsupportedAssociation`. Explicitly *not* part of the v1.0 contract
(may work accidentally, no promised behavior): HABTM join-table replication,
`has_many :through`, `has_one :through`, polymorphic associations, complicated STI
dispatch, deferrable dependency cycles.

## Association types

| Association | Verdict | Evidence / gap |
|---|---|---|
| belongs_to | Covered | Parent copied + FK remapped: `spec/deckard/active_record_spec.rb:32-49`. Nil FK stays nil: `active_record_spec.rb:75-83`. Omit by name and by FK column: `spec/deckard/model_api_spec.rb:102-116`. Optional (`Book`) and required (`Profile`) both exercised. Gap: no test isolates required-belongs_to-with-nil-FK (would surface as a normal NOT NULL failure on load). |
| has_one | Partial | Child discovered, FK remapped: `active_record_spec.rb:51-59`. Absent child covered only implicitly (exact `dumper.counts` assertions would catch a phantom dump). Gap: no natural-key replacement test on a has_one target — `Profile` has no `natural_key`; the only update-in-place test is `Reader`/`ReaderEmail` (`model_api_spec.rb:118-136`), reached via has_many. Same loader code path, but the shape is untested. |
| has_many | Covered (opt-in path) | Opt-in traversal + many children + FK remap: `model_api_spec.rb:36-46`. Reachable-via-two-paths dedup: `spec/deckard/edge_cases_spec.rb:72-87`. Per-dump `associations:` incl. classes lacking the name: `model_api_spec.rb:78-89`. Gaps: zero-children case had no test (verified: works — counts `{"Library"=>1}`, clean load, zero books); same-collection-dumped-twice tested only with plain-Ruby fixtures (`spec/deckard/stream_spec.rb:122-133`), not at the AR level. |
| has_and_belongs_to_many | No coverage; silent half-work (verified) | Zero HABTM models or references in the repo. Verified by running: a `Club` with `associations :club_members` dumps the club and both members, the loader inserts copies of all three rows, and the join table gets nothing — the loaded club has zero members and no error is raised. This violates the spec's "fail clearly rather than approximate" principle even though HABTM is out of contract. |
| has_many :through | No coverage; silent half-work for the far side, works via the join model (verified) | Naming the `:through` association (`associations :patients`) dumps physician + patients but never the appointment join rows — loaded copies exist with no linkage, silently. Naming the *join model* instead (`associations :appointments`) round-trips the full graph correctly: the appointment's two belongs_to pull in both sides and the new physician sees its patients. So the supported pattern exists; the far-side name is the trap. |
| has_one :through | No coverage; round-tripped fully in the common shape (verified) | `Supplier -> Account -> AccountHistory` with `associations :account_history` loaded completely — but only because `has_one :account` is auto-traversed anyway, which carries the intermediate row; the configured through-name dumps the far side and dedup does the rest. A shape whose intermediate is not an automatic belongs_to/has_one would half-work like has_many :through. |
| Polymorphic belongs_to | Covered | Populated raises `UnsupportedAssociation` with exact message: `active_record_spec.rb:119-127`. Nil does not raise: `active_record_spec.rb:75-83`. Omitting a populated polymorphic FK (verified): omission wins over the raise and `billable_id` is dropped — but `billable_type` still streams and loads, leaving a dangling type string ("Author") next to a nil id on the destination row. Probably should drop the type column alongside the FK. |
| Polymorphic has_many / has_one | No coverage; fails clearly (verified) | No test model has the reverse side. Verified by running: `Author has_many :payments, as: :billable` opted in via `associations:` traverses into the payment, whose populated polymorphic belongs_to then raises `UnsupportedAssociation`. So the reverse side is unreachable in practice and fails loudly — no code change needed, one documenting test would close it. |
| Self-referential | Covered (belongs_to) | `Employee belongs_to :manager, class_name: "Employee"`, 3-level chain round-tripped with remapped FKs: `edge_cases_spec.rb:56-70`. Self-loop row (`manager_id == id`), verified: raises `Deckard::DumpError` "dependency cycle detected: Employee(1).manager references Employee(1)". True as far as the emit-order model goes, but a legitimately self-parented row cannot be dumped at all — decide whether that is acceptable v1.0 behavior (it matches "deferrable cycles are unsupported") or worth special-casing. No self-referential has_many test either way. |
| STI | Partial | Subclass name streamed and referenced (`SpecialLibrary`, not `Library`): `edge_cases_spec.rb:89-99`. Config inheritance: `spec/deckard/model_config_spec.rb:23-38` and `model_api_spec.rb:61-69`. `type` column round-trip proven indirectly (STI-scoped `.sole` query passes). "Complicated STI dispatch" is an explicit spec non-goal. |

## Identity, remapping, and graph topology

| Item | Verdict | Evidence / gap |
|---|---|---|
| Source IDs differ from destination IDs | Covered | Gem spec: `active_record_spec.rb:32-49` (`where.not(id:)` + FK equality on new ids). E2E adds the stronger proof: destination sequences advanced to 100000 (`harness/script/reset_dest_sequences.rb`) and every loaded id asserted `>= 100000` (`harness/bin/verify:17-18`). |
| Remapping across PK types | Covered | bigint: `active_record_spec.rb:32-49`. UUID: `edge_cases_spec.rb:42-54` (Ship/Cargo, `gen_random_uuid()` PKs). Harness is integer-only. |
| Shared child / dedup | Covered | AR: `active_record_spec.rb:61-73` (one author, two referrers, counts == 1, both FKs converge). Protocol level: `stream_spec.rb:105-120`. E2E: cross-referenced authors, `harness/bin/verify:29`. |
| Empty association | Works, untested | Nil belongs_to covered (`active_record_spec.rb:75-83`). Zero-dependents record verified by running: bare author dumps as `{"Author"=>1}` and loads cleanly. Needs a regression test, not a fix. |
| One child / many children | Covered | `active_record_spec.rb:51-59`; `model_api_spec.rb:36-46`. |
| Diamond graph | Partial | The re-entrancy variant (book -> library -> books collection -> same book) is tested: `edge_cases_spec.rb:72-87`. The classic two-arm diamond (A->B, A->C, both -> D) is only implied by shared-child tests, never named. |
| Self-loop row | Raises (verified), untested | `manager_id == id` raises `DumpError` as a dependency cycle — see the self-referential row above. Behavior now known; a test should pin whichever behavior we decide is right. |
| Actual dependency cycle | Covered | `CycleA`/`CycleB` raise `Deckard::DumpError` /dependency cycle/: `active_record_spec.rb:129-135`. |
| Idempotency | Partial | Dump-twice-emits-once: `stream_spec.rb:122-133`. Natural-key reuse (update, no duplicate) and ambiguity error: `model_api_spec.rb:118-136`, `148-159`. Double-load verified by running: loading the same author+post stream twice yields duplicate rows (1 source + 2 loaded copies of each), exactly the spec 10.3 behavior ("never updates or deletes existing destination records" without a natural key) — correct, but asserted nowhere. |
| Stream ordering | Partial | One direct frame-order assertion (`edge_cases_spec.rb:89-99`) plus the reference-precedes-object failure test (`stream_spec.rb:166-177`); every other round trip proves ordering only implicitly (a violation would raise `UnresolvedReference`). |

## E2E harness topology

The harness graph (Author/Profile/Post/Comment, dumped via `Comment.all`) exercises:
belongs_to chains, has_one, shared authors, sequence-divergence id proof, encryption
re-key, PG enum, generated column. It does not exercise UUID PKs, self-reference,
diamonds, cycles, or natural keys — by design, those live in the gem-spec tier.

## Proposed follow-ups (for review — none done)

In-contract gaps — behavior verified correct, each needs a small regression test:

- [ ] Zero-dependents record: dump a bare record, assert `counts == {"Type"=>1}` and clean load
- [ ] Zero-children opted-in has_many (library with no books)
- [ ] Double-load of a non-natural-key stream: assert the duplicate-rows behavior (spec 10.3)
- [ ] has_one target with a natural key: pre-seed destination child, assert update-in-place, not a duplicate (same loader path as the Reader test, but the shape is untested)
- [ ] Classic two-arm diamond, named as such, asserting single emission of the shared grandchild
- [ ] Same AR collection dumped twice in one script emits rows once
- [ ] Self-loop row: pin the verified `DumpError` behavior with a test (or decide to support it and change code)
- [ ] Polymorphic has_many reverse side: one test documenting the verified `UnsupportedAssociation` raise

Verified warts needing a decision (behavior change, not just a test):

- [ ] HABTM and far-side `has_many :through` named in `associations` silently half-work: target rows load, join rows/linkage never do, no error. Recommend raising `UnsupportedAssociation` for association macros other than belongs_to/has_one/has_many ("fail clearly rather than approximate"); the working alternative — opting in the join model, which round-trips fully — belongs in the error message and README
- [ ] Omitting a populated polymorphic belongs_to drops the FK but streams the `*_type` column, loading a dangling type next to a nil id. Recommend dropping the type column alongside the FK when the omitted association is polymorphic
