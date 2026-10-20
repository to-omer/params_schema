# Development

Run the commands below from the repository root. Nix supplies Ruby, Bundler, and
the system tools; Bundler installs gems under `vendor/bundle`.

## Setup and checks

Install Nix with flakes enabled. With [direnv's shell hook](https://direnv.net/docs/hook.html)
enabled, allow this checkout once:

```sh
direnv allow
BUNDLE_FROZEN=true bundle install
bundle exec rbs collection install --frozen
bundle exec rake test rubocop yard typecheck package_check
```

Direnv loads the default Nix shell when you enter the directory and unloads it
when you leave. Without direnv, enter the same shell with `nix develop path:.`.
The default shell uses Ruby 4.0 and includes both Gemfile groups: `test` and
`development`.

`rake` runs the tests. `typecheck` validates the public RBS signatures, checks valid
and invalid API calls with Steep, and checks a consumer fixture against RBS at
runtime.

`package_check` builds and installs the gem and its runtime dependencies in a
temporary directory, then verifies the installed API and signatures using
`test/types/consumer.rb`. It uses cached gems from the current bundle.

## API documentation

```sh
bundle exec rake yard
open doc/index.html
```

YARD builds the API reference and examples from `lib/`, with `docs/index.md` as
the landing page and the guides listed in `.yardopts`.
Documentation warnings fail the build. Use `xdg-open` instead of `open` on Linux.

For GitHub Pages, set **Settings → Pages → Source** to **GitHub Actions**. The CI
workflow deploys `doc/` from the default branch after all checks pass. Pull
requests build the site without deploying it. The configured URL is
<https://to-omer.github.io/params_schema/>.

## Compatibility checks

The `ruby32`, `ruby33`, `ruby34`, and `ruby40` shells exclude the `development`
group. Test each shell with both committed lockfiles:

| Gemfile | Rails | Lockfile |
| --- | --- | --- |
| `Gemfile` | 8.1 | `Gemfile.lock` |
| `gemfiles/rails_8_0.gemfile` | 8.0 | `gemfiles/rails_8_0.gemfile.lock` |

For example, run both Rails versions on Ruby 3.2:

```sh
nix develop path:.#ruby32
for gemfile in Gemfile gemfiles/rails_8_0.gemfile; do
  BUNDLE_GEMFILE="$gemfile" BUNDLE_FROZEN=true bundle install
  BUNDLE_GEMFILE="$gemfile" bundle exec rake test
done
```

CI runs all eight combinations with frozen lockfiles. Resolve dependency updates
in the default Ruby 4.0 shell; the latest development tools require newer Ruby
versions than the library itself. Rails 8.0 uses JSON 2 because it passes options
that JSON 3 rejects.

Nix shells support Apple Silicon macOS and Linux on x86_64 or aarch64.

## Updating dependencies

`flake.lock` pins the toolchains, the two Bundler lockfiles pin gems, and
`rbs_collection.lock.yaml` pins external signatures. Keep these files in version
control and review changes when updating dependencies.

```sh
nix develop path:.
bundle update
BUNDLE_GEMFILE=gemfiles/rails_8_0.gemfile bundle update
bundle exec rbs collection update
bundle exec rake test rubocop yard typecheck package_check
```

Then run the compatibility checks above. Use `nix flake update` to update Nixpkgs.
When its Ruby packages lag [upstream releases](https://www.ruby-lang.org/en/downloads/releases/),
update the Ruby source versions and hashes in `flake.nix` as well.
When updating Bundler, keep its version and gem hash in `flake.nix` aligned with
`BUNDLED WITH` in both lockfiles.

Workflow actions are pinned to commits. `pinact run --fix=false --no-api` checks
pin format; `pinact run --update` updates pins from upstream releases.

## Building and releasing

`bundle exec rake build` writes the gem to `pkg/`.

Before publishing a release:

1. Verify ownership of the RubyGems name and access to the GitHub repository.
   Check that the source and documentation URLs in the gemspec are available.
2. Update `lib/params_schema/version.rb` and record user-visible changes in
   `CHANGELOG.md`. Run `bundle install` for both Gemfiles to update the local
   gem's version in their lockfiles.
3. Run the checks above and inspect the built gem and documentation. Commit the
   release changes, including both lockfiles.
4. From a clean checkout, run `bundle exec rake release`. Bundler's release task
   builds the gem, pushes its version tag, and publishes it to RubyGems.
