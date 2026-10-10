# Releasing Deckard

A version increase is the release trigger. In one pull request, update
`Deckard::VERSION` in `lib/deckard/version.rb` and add a nonempty matching
version section to `CHANGELOG.md`. The release check rejects a version change
without matching release notes. Changes that leave the version unchanged do
not create tags, publish gems, or create GitHub releases.

Use the repository's normal pull request checks and GitHub ruleset before
merging. After a version increase reaches `main`, the official
`rubygems/release-gem` action and Bundler handle the gem build, version tag,
OIDC authentication, publication, and availability wait. The shared workflow
checks the version and release notes and creates the GitHub release from the
matching changelog section. It does not poll CI after merge.

Keep the version and notes in the reviewed pull request; there is no automated
version bump after merge.

The small workflow in `.github/workflows/release.yml` calls a reusable workflow in
[`rsanheim/.github`](https://github.com/rsanheim/.github), pinned to an
immutable commit. Release logic lives in that repository. Update
the workflow reference after reviewing a shared workflow change.
The shared workflow change must be merged before merging a consumer update.

## One-time RubyGems setup

Before merging the first version increase, a Deckard gem owner must configure
a RubyGems trusted publisher. This repository change does not configure the
RubyGems account.

Use these values in the trusted publisher form:

| Field | Value |
| --- | --- |
| Repository owner | `rsanheim` |
| Repository name | `deckard` |
| Workflow filename | `gem-release.yml` |
| Workflow Repository Owner | `rsanheim` |
| Workflow Repository Name | `.github` |
| Environment | `release` |

The workflow filename identifies the reusable workflow. The separate workflow
repository fields are required for this setup; see the
[RubyGems reusable workflow instructions](https://guides.rubygems.org/trusted-publishing/#using-reusable-workflows).
Publishing uses short-lived OIDC credentials, so no persistent RubyGems API
key is needed in GitHub secrets.

If publication fails before the gem is uploaded, fix the cause and manually
run the Release workflow on `main`, setting `previous-ref` to the tag before
the version increase. Confirm the target version is still unpublished before
retrying.
