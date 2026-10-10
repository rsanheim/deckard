# Releasing Deckard

A version increase is the release trigger. In one pull request, update
`Deckard::VERSION` in `lib/deckard/version.rb` and add a nonempty matching
version section to `CHANGELOG.md`. The release check rejects a version change
without matching release notes. Changes that leave the version unchanged do
not create tags, publish gems, or create GitHub releases.

After the pull request merges into `main`, automation waits for
`ci/crow/push/ruby` to succeed on that exact commit, creates or verifies its
`vVERSION` tag, publishes with the stock `rubygems/release-gem` action, and
creates the GitHub release from the matching changelog section. Keep the
version and notes in the reviewed pull request; there is no automated version
bump after merge.

The small workflow in `.github/workflows/release.yml` calls a reusable workflow in
[`rsanheim/.github`](https://github.com/rsanheim/.github), pinned to an
immutable commit. Release logic and its tests live in that repository. Update
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
| Environment | Leave blank |

The workflow filename identifies the reusable workflow. The separate workflow
repository fields are required for this setup; see the
[RubyGems reusable workflow instructions](https://guides.rubygems.org/trusted-publishing/#using-reusable-workflows).
Publishing uses short-lived OIDC credentials, so no persistent RubyGems API
key is needed in GitHub secrets.

## Recovering a failed release

Review the failed Actions run and fix its cause, then rerun the workflow for
the same commit. An existing version tag must point to that commit. Never move
an existing release tag or reuse a published version for changed contents.
