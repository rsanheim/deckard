# Build context is the deckard repo root (see docker-compose.yml) so the
# harness app can use the gem via its path dependency.
FROM ruby:4.0-slim

RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends build-essential libpq-dev libyaml-dev git postgresql-client && \
    rm -rf /var/lib/apt/lists/*

# Keep dependency installation cached when only Deckard or harness source changes.
COPY harness/Gemfile /deckard/harness/Gemfile
COPY deckard.gemspec README.md /deckard/
COPY exe/deckard /deckard/exe/deckard
COPY lib/deckard/version.rb /deckard/lib/deckard/version.rb

WORKDIR /deckard/harness
RUN bundle install

COPY . /deckard
