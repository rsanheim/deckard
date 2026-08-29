# Build context is the deckard repo root (see docker-compose.yml) so the
# harness app can use the gem via its path dependency.
FROM ruby:4.0-slim

RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends build-essential libpq-dev libyaml-dev git postgresql-client && \
    rm -rf /var/lib/apt/lists/*

COPY . /deckard
WORKDIR /deckard/harness

RUN bundle install
