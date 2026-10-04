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
3. Add a licence before the first release (see README).

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
