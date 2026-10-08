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

## GitHub Packages and Releases

The `github` job in `.github/workflows/release.yml` runs on the same `v*` tags. It repeats the tag check and the
specs, then:

- pushes the gem to GitHub Packages (`https://rubygems.pkg.github.com/Docuconf`); the `github_repo` metadata in the
  gemspec links it to this repository;
- creates the GitHub Release for the tag if it does not exist, and attaches `docuconf-anyway-<version>.gem`.

It does not depend on the RubyGems.org `release` job, so it works before the trusted publisher and the `release`
environment exist. It authenticates with the workflow's own `GITHUB_TOKEN` (`packages: write`, `contents: write`);
there are no secrets or accounts to set up. The only requirement is that the `Docuconf` organization lets
`GITHUB_TOKEN` write packages, which it does unless package creation has been restricted under Organization settings >
Packages.

### Installing from GitHub Packages

GitHub's RubyGems registry requires a token even for public gems. Create a personal access token (classic) with the
`read:packages` scope. With Bundler, add the source to the `Gemfile`:

```ruby
source "https://rubygems.pkg.github.com/Docuconf" do
  gem "docuconf-anyway"
end
```

and give Bundler the credentials (the username is your GitHub username):

```sh
bundle config set --global https://rubygems.pkg.github.com/Docuconf YOUR_GITHUB_USERNAME:"$GITHUB_TOKEN"
```

With plain `gem`:

```sh
gem sources --add "https://YOUR_GITHUB_USERNAME:$GITHUB_TOKEN@rubygems.pkg.github.com/Docuconf/"
gem install docuconf-anyway
```

Without a token, download the `.gem` from the GitHub Release and run `gem install ./docuconf-anyway-0.1.0.gem`.

## docuconf-go version

docuconf-go owns the spec, the CUE meta-schema (`spec/cue`), the conformance suite (`conformance/cases.json`) and the
`docuconf` CLI. This SDK is tested against one docuconf-go commit, pinned in `.github/docuconf-go.ref` (a full SHA).

- **CI** checks out that commit on pushes and pull requests. The nightly scheduled run uses docuconf-go `main` instead,
  so a spec change that breaks this SDK shows up within a day. To try another docuconf-go commit or branch, run the CI
  workflow by hand (Actions, CI, Run workflow) with `docuconf_go_ref` set.
- **Bump PRs.** `.github/workflows/docuconf-go-bump.yml` opens (or updates) a `build(deps): bump docuconf-go to <sha>`
  pull request from the `docuconf-go-bump` branch whenever docuconf-go `main` moves: immediately when docuconf-go sends
  a `docuconf-go-updated` dispatch (this needs the release GitHub App), otherwise on its daily schedule. CI on that PR
  is the compatibility check; merge it when it is green, or fix the SDK on the same branch. It can also be run by hand
  with a specific `sha`.
- **`scripts/conformance.sh`** runs only the docuconf-go-facing checks (the conformance suite and the `cue vet` of
  exported contracts) against any checkout: `DOCUCONF_GO_DIR=../docuconf-go scripts/conformance.sh`. CI runs it, and
  so does docuconf-go's downstream workflow, which runs it against every docuconf-go pull request that touches the spec,
  the conformance suite or the CLI. It needs Ruby 3.2+, Bundler and `cue` on `PATH`.

Without the release App (secrets `RELEASE_APP_ID` and `RELEASE_APP_PRIVATE_KEY`) the bump workflow uses
`GITHUB_TOKEN`: the repository setting "Allow GitHub Actions to create and approve pull requests" must be on, and
because a PR opened that way triggers no workflows, the bump workflow starts CI on the branch itself
(`workflow_dispatch`, whose checks show on the PR).
