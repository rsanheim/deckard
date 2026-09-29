# Deckard

Deckard allows you to replicate ActiveRecord object with underlying data between environments. It does this by smartly traversing associations, remapping id's and avoiding cycles. 

It is inspired by the old gem [replicate](https://github.com/rtomayko/replicate), but updated for modern ActiveRecord 8 and up. Right now it only targets PostgreSQL.
Its primary use is piping selected production
records into a local development database for debugging and realistic
development data.


```bash
ssh example.org "deckard -r /app/config/environment -d 'User.find(1234)'" \
  | deckard -r ./config/environment -l
```

Records arrive with new destination-generated primary keys; foreign keys are
rewritten to match. Loads run in one transaction that commits only when the
stream ends cleanly, and the default loader bypasses validations and
callbacks — it copies data, it does not run your application.

## Installation

Add Deckard to each environment that will dump or load:

```ruby
gem "deckard"
```

## Dumping

Evaluate a Ruby expression and write the object stream to standard output:

```bash
deckard -r ./config/environment -d "User.find(1)" > user.dump
```

Diagnostics go to standard error; standard output carries only the stream:

```text
dumped 4 total objects:

Profile    1
User       1
UserEmail  2
```

Application boot code that prints to stdout (a logger pointed at `STDOUT`,
a stray `puts` in an initializer) cannot corrupt the stream: before requiring
the application, Deckard keeps the original stdout for itself and points file
descriptor 1 at stderr, so everything else the process prints lands there.

Dumping a record automatically includes its `belongs_to` and `has_one`
associations. `has_many` collections are only dumped when opted in (see
below) — they can pull in a large slice of the database.

For more involved selection, pass a Ruby file instead of an expression. The
script runs in a context exposing `dump(object)`:

```ruby
# config/deckard/dump-stuff.rb
require "./config/environment"

repo = Repository.find_by(name: "tilt")
dump repo
dump repo.issues
```

```bash
deckard -d config/deckard/dump-stuff.rb > repos.dump
```

Extra command-line arguments reach the script through `ARGV`, and `-d -`
reads the script from standard input. An expression given to `-d` runs in
the same context, so it may call `dump` directly. While stderr is a
terminal, a live object counter shows progress on both ends of the pipe.

## Loading

Load a stream from standard input:

```bash
deckard -r ./config/environment -l < repos.dump
```

Loading refuses to run when the application environment is production.
Pass `--force` to override.

## Streaming over SSH

The normal remote workflow is a plain Unix pipeline — SSH is the transport,
and no intermediate file is needed:

```bash
remote_command="deckard -r /app/config/environment -d 'User.find(1234)'"

ssh example.org "$remote_command" \
  | deckard -r ./config/environment -l
```

Both ends stream: the destination begins inserting while the source is still
traversing. If the remote side dies mid-stream, the destination transaction
rolls back and nothing is committed.

## Model configuration

A dump starts from one model, and that model's `replicate` block is the plan
for the whole dump: what the root carries, and how every model the dump
reaches is dumped and matched.

```ruby
class Order < ActiveRecord::Base
  belongs_to :customer
  has_many :line_items

  replicate do
    associations :line_items       # opt this has_many into dumps
    natural_key :number            # reuse an existing destination row
    omit_fields :internal_notes    # keep a field out of the stream
    omit_associations :warehouse   # do not traverse this association

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

`model` takes a class name and a block with the same four methods. A dump
follows its root's plan and nothing else: `dump Order.find(1)` uses Order's
block for every record it reaches, and `dump LineItem.find(1)` uses
LineItem's. A reached class's own block is not consulted, so there is nothing
to merge and no precedence to learn. Classes are named as strings, so the
root never forces them to load first, and an STI subclass follows the entry
for its nearest declared ancestor. Each record travels with the natural key
its plan gave it, so the destination needs no plan of its own.

Before dumping or loading, the `deckard` executable eager loads the
application so every `replicate` block has run, then validates the whole
plan: each named class must be a loaded ActiveRecord model, and each named
association and attribute must exist on it. A bad plan fails there, reporting
every problem at once, before any record is dumped or loaded.

## Security

The stream is Ruby `Marshal` data: load streams only from applications and
operators you trust, over an authenticated transport such as SSH. Deckard is
an internal operator tool, not a public import format. Dumped production data
lands unmasked in the destination database — treat dumps accordingly. That
includes ActiveRecord-encrypted attributes: they travel through the stream as
plaintext and are re-encrypted with the destination's keys on load.

## Development

`bundle exec rake` runs the unit/integration suite (specs against a local
PostgreSQL 18, lint, and a style ratchet). The specs run against a small forum
schema managed with ActiveRecord's own migration and schema tooling under
`spec/db`; `bundle exec rake -T db` lists the database tasks, and
`bundle exec rake db:reset` rebuilds and seeds the test databases from scratch.
`bundle exec rake e2e` runs the
full-stack test: a real Rails app streaming between two docker compose
containers. `bundle exec rake test-all` runs both host-side checks and the
full-stack test. See `docs/spec.md` for the v1.0 specification.

Crow CI runs `bundle exec rake` on pull requests, default-branch pushes, and
manual runs using Ruby 4.0.6 and an isolated PostgreSQL 18.6 service. The workflow
is in `.crow/ruby.yaml`; it covers specs, Standard lint, and the style ratchet.
The Docker end-to-end harness and performance suite remain separate local tasks.
