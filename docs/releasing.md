# Releasing Deckard

Setup, trusted publishing, workflow updates, verification, and recovery live in
[the shared release guide](https://github.com/rsanheim/.github#readme).

Deckard quick reference:

1. Update `lib/deckard/version.rb` and add matching notes to `CHANGELOG.md`.
2. Synchronize Deckard's version in the PATH and CHECKSUMS entries of
   `Gemfile.lock`.
3. Run `bundle exec rake` and `BUNDLE_FROZEN=true bundle exec rake build`.
4. Merge the reviewed PR to `main` to publish.

The caller is [`.github/workflows/release.yml`](../.github/workflows/release.yml).
