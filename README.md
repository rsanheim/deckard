# Deckard

Deckard copies selected ActiveRecord records, and the records they need,
from one Rails environment into another. Pick a record, and its plan says
what comes with it. Rows land with new primary keys, foreign keys are
rewritten to match, and the load commits only when the stream ends cleanly.
Its usual job is pulling one production record and its graph into a local
development database to debug against real data.

It is inspired by [replicate](https://github.com/rtomayko/replicate), rebuilt
for ActiveRecord 8 and PostgreSQL.

## Quick start

Add the gem to both applications:

```ruby
gem "deckard"
```

Put a plan on the model you dump from. It names the collections that come
along and how each model the dump reaches is matched on the destination:

```ruby
class Order < ActiveRecord::Base
  belongs_to :customer
  has_many :line_items

  replicate do
    associations :line_items

    model "LineItem" do
      associations :adjustments
    end

    model "Customer" do
      natural_key :email
      omit_fields :password_digest
    end
  end
end
```

From your development machine, dump on the remote side and load locally in
one pipe. SSH is the transport; nothing lands on disk:

```bash
ssh prod.example.org "deckard -r /app/config/environment -d 'Order.find(1234)'" \
  | deckard -r ./config/environment -l
```

Standard error on each end reports what moved:

```text
loaded 9 total objects:

Adjustment  3
Customer    1
LineItem    4
Order       1
```

The customer was matched by email, so an existing local customer was updated
rather than duplicated. Everything else is a new row with a new id.

To keep a dump around, write it to a file and load it later:

```bash
deckard -r ./config/environment -d "Order.find(1234)" > order.dump
deckard -r ./config/environment -l < order.dump
```

## What a dump carries

Dumping a record includes the rows it depends on (`belongs_to`), the record
itself, the rows it owns one-to-one (`has_one`), and the collections its plan
names. `has_many` collections are never followed on their own.

A dump follows its root's plan and nothing else: `dump Order.find(1)` uses
Order's block for every record it reaches, and `dump LineItem.find(1)` uses
LineItem's. A reached class's own block is not consulted, so there is nothing
to merge and no precedence to learn.

A record reached only through `belongs_to` is a dependency: it arrives as a
row with its own dependencies, so foreign keys resolve, and nothing it owns,
whatever its entry says. The line item's product comes along; the product's
reviews do not. That rule is what keeps a dump the size of one record's
ownership tree. [docs/traversal.md](docs/traversal.md) draws it.

Each record handed to `dump` is a root, so `dump Order.where(customer_id: 7)`
gives every order the full plan, and a record two dumps share lands once.

## Plans

The `replicate` block offers five methods:

```ruby
replicate do
  associations :line_items       # opt this has_many into dumps
  natural_key :number            # reuse an existing destination row
  omit_fields :internal_notes    # keep a field out of the stream
  omit_associations :warehouse   # do not traverse this association

  model "LineItem" do            # the same four, for a class the dump reaches
    associations :adjustments
  end
end
```

Classes are named as strings, so the root never forces them to load first,
and an STI subclass follows the entry for its nearest declared ancestor. Each
record travels with the natural key its plan gave it, so the destination
needs no plan of its own. That also means a natural key is repeated in every
plan whose dumps reach the class: a Customer entry in Order's plan and one in
Invoice's, each saying how a customer is matched.

Before dumping, the `deckard` executable eager loads the application so
every `replicate` block has run, then validates every plan: each named class
must be a loaded ActiveRecord model, and each named association and attribute
must exist on it. A bad plan fails there, reporting every problem at once,
before any record is dumped. Loading consults no plan at all.

To see a plan before pointing it at production, print it:

```bash
deckard -r ./config/environment --plan Order
deckard -r ./config/environment --plan Order --format json
```

```text
Order
  associations      line_items

LineItem
  associations      adjustments

Customer
  natural key       email
  omit fields       password_digest
```

## Dumping

`-d` evaluates a Ruby expression and streams the result to standard output.
Diagnostics go to standard error; standard output carries only the stream.
Application boot code that prints to stdout (a logger pointed at `STDOUT`, a
stray `puts` in an initializer) cannot corrupt it: before requiring the
application, deckard keeps the original stdout for itself and points file
descriptor 1 at stderr.

For more involved selection, pass a Ruby file instead of an expression. The
script runs in a context exposing `dump(object)`:

```ruby
# config/deckard/dump-repo.rb
repo = Repository.find_by!(name: ARGV.first)
dump repo
dump repo.issues
```

```bash
deckard -r ./config/environment -d config/deckard/dump-repo.rb tilt > repos.dump
```

Extra command-line arguments reach the script through `ARGV`, and `-d -`
reads the script from standard input. An expression given to `-d` runs in
the same context, so it may call `dump` directly. While stderr is a
terminal, a live object counter shows progress on both ends of the pipe.

## Loading

`-l` reads a stream from standard input and loads it inside one transaction,
bypassing validations and callbacks: it copies data, it does not run your
application. If the source dies mid-stream, nothing is committed.

Loading refuses to run when the application environment is production. Pass
`--force` to override.

## Security

The stream is Ruby `Marshal` data: load streams only from applications and
operators you trust, over an authenticated transport such as SSH. Deckard is
an internal operator tool, not a public import format. Dumped production data
lands unmasked in the destination database; treat dumps accordingly. That
includes ActiveRecord-encrypted attributes: they travel through the stream as
plaintext and are re-encrypted with the destination's keys on load.

## Development

`bundle exec rake` runs the unit/integration suite (specs against a local
PostgreSQL 18, lint, and a style ratchet); `bin/rspec spec/deckard/stream_spec.rb`
runs one file. The specs run against a small forum
schema managed with ActiveRecord's own migration and schema tooling under
`spec/db`; `bundle exec rake -T db` lists the database tasks, and
`bundle exec rake db:reset` rebuilds and seeds the test databases from scratch.
`bundle exec rake e2e` runs the full-stack test: a real Rails app streaming
between two docker compose containers. `bundle exec rake test-all` runs both
host-side checks and the full-stack test. See `docs/spec.md` for the v1.0
specification and `docs/traversal.md` for how a dump walks the graph.

Crow CI runs `bundle exec rake` on pull requests, default-branch pushes, and
manual runs using Ruby 4.0.6 and an isolated PostgreSQL 18.6 service. The
workflow is in `.crow/ruby.yaml`; it covers specs, Standard lint, and the
style ratchet. The Docker end-to-end harness and performance suite remain
separate local tasks.
