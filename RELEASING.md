# Releasing docuconf-anyway

Releases are published to [RubyGems.org](https://rubygems.org/gems/docuconf-anyway) by
[`.github/workflows/release.yml`](.github/workflows/release.yml) using
[trusted publishing](https://guides.rubygems.org/trusted-publishing/): GitHub Actions gets a short-lived
OIDC token, so no RubyGems API key is stored anywhere.

## One-time setup

1. On RubyGems.org, add a trusted publisher for the gem (before the first release, a *pending* trusted
   publisher, since the gem does not exist yet):
   - gem name: `docuconf-anyway`
   - repository: `docuconf/docuconf-ruby`
   - workflow: `release.yml`
   - environment: `release`
2. In the GitHub repository, create an environment named `release`. Restrict it to tags matching `v*` and
   add required reviewers if releases should be approved.

## Each release

Releases are automated with [release-please](https://github.com/googleapis/release-please); see
[CONTRIBUTING.md](CONTRIBUTING.md#how-releases-happen) for the commit conventions it reads.

1. Merge the open release PR (`chore(main): release X.Y.Z`). It already bumps `Docuconf::Anyway::VERSION` in
   `lib/docuconf/anyway/version.rb` (semver; the API is pre-1.0, so breaking changes bump the minor version) and
   updates `CHANGELOG.md`. The golden contract and the example contract do not need regenerating: their
   comparisons ignore `metadata.generator.version`.
2. release-please tags the merge commit `vX.Y.Z` and creates the GitHub release, with the changelog entries as its
   notes.
3. `.github/workflows/release.yml` runs on the tag: it checks that the tag matches `VERSION`, runs the specs,
   builds the gem and pushes it with [`rubygems/release-gem`](https://github.com/rubygems/release-gem).

If the release PR was created with `GITHUB_TOKEN` (no release GitHub App configured), the tag does not trigger
`release.yml` by itself, so `.github/workflows/release-please.yml` starts it with `gh workflow run`. To redo a
release by hand: `gh workflow run release.yml --ref vX.Y.Z`.

To check the package locally without publishing: `gem build docuconf-anyway.gemspec` and inspect the
file list with `gem spec docuconf-anyway-*.gem files`.
