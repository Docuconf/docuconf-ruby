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

1. Update `Docuconf::Anyway::VERSION` in `lib/docuconf/anyway/version.rb` (semver; the API is
   pre-1.0, so breaking changes bump the minor version).
2. Regenerate the golden contract if the generator version appears in it:
   `UPDATE_GOLDEN=1 bundle exec rspec spec/export_spec.rb`, and review the diff.
3. Commit, then tag and push:

   ```sh
   git tag v0.1.0
   git push origin main v0.1.0
   ```

4. The workflow checks that the tag matches `VERSION`, runs the specs, builds the gem and pushes it with
   [`rubygems/release-gem`](https://github.com/rubygems/release-gem).
5. Write release notes on the GitHub release for the tag.

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
