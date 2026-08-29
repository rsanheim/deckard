# Deckard

Deckard streams ActiveRecord objects between Rails environments — a modern
resurrection of the [replicate](https://github.com/rtomayko/replicate) gem for
ActiveRecord 8+ and PostgreSQL. Its primary use is piping selected production
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

Dumping a record automatically includes its `belongs_to` and `has_one`
associations. `has_many` collections are only dumped when opted in (see
below) — they can pull in a large slice of the database.

For more involved selection, pass a Ruby file instead of an expression. The
script runs in a context exposing `dump(object, options = {})`:

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

## Loading

Load a stream from standard input:

```bash
deckard -r ./config/environment -l < repos.dump
```

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

```ruby
class User < ActiveRecord::Base
  belongs_to :profile
  has_many :email_addresses

  replicate do
    associations :email_addresses   # opt this has_many into dumps
    natural_key :login              # reuse an existing destination row
    omit :encrypted_password        # keep an attribute out of the stream
  end
end
```

A dump call can also add associations or omissions for just that dump:

```ruby
dump User.all, associations: [:email_addresses], omit: [:created_at]
```

## Security

The stream is Ruby `Marshal` data: load streams only from applications and
operators you trust, over an authenticated transport such as SSH. Deckard is
an internal operator tool, not a public import format. Dumped production data
lands unmasked in the destination database — treat dumps accordingly. That
includes ActiveRecord-encrypted attributes: they travel through the stream as
plaintext and are re-encrypted with the destination's keys on load.

## Development

`bundle exec rake` runs the unit/integration suite (specs against a local
PostgreSQL 18, lint, and a style ratchet). `bundle exec rake e2e` runs the
full-stack test: a real Rails app streaming between two docker compose
containers. See `docs/spec.md` for the v1.0 specification.
