# docuconf-anyway

The Ruby SDK for [docuconf](https://github.com/docuconf): typed configuration contracts between an
application and the Kubernetes platform that runs it.

Documentation: [docuconf.dev](https://docuconf.dev) · [Ruby guide](https://docuconf.dev/languages/ruby/)

It extends [anyway_config](https://github.com/palkan/anyway_config) rather than replacing it. You keep your
`Anyway::Config` classes (`attr_config`, `required`, `config_name`, `env_prefix`, YAML, credentials), and add
one `describe` line per attribute. docuconf then:

1. checks every variable and mounted file at boot and reports every problem at once, each with a stable code,
   never printing a secret;
2. exports the same declaration as a `contract.cue`, so the platform rejects bad configuration before it
   deploys.

> Status: v0.1, implementing [spec v1alpha1](https://github.com/docuconf/docuconf-go/blob/main/spec/SPEC.md).
> Expect breaking changes until v1. Example app: [`examples/orders`](examples/orders).

1. [Install](#install)
2. [Declare](#declare)
3. [Run](#run)
4. [See an error](#see-an-error)
5. [Test your config](#testing-your-config)
6. [Export the contract](#export-the-contract)
7. [Deploy](#deploy)
8. [Rails](#rails)
9. [Troubleshooting](#troubleshooting)
10. [Reference](docs/reference.md)

## Install

The gem is not on RubyGems yet. Use it from git:

<!-- readme: gemfile -->
```ruby
# Gemfile
gem "docuconf-anyway", github: "Docuconf/docuconf-ruby"
```

```sh
bundle install
```

Or from a local checkout: `gem "docuconf-anyway", path: "../docuconf-ruby"`. `gem "docuconf-anyway"` from
RubyGems will work from the first release.

Requires Ruby 3.2+ and anyway_config 2.6+. Bundler requires `docuconf/anyway` for you, and in Rails the
Railtie loads automatically.

## Declare

Add `include Docuconf::Anyway` to an anyway_config class, and a `describe` for each attribute:

<!-- readme: config -->
```ruby
# config/configs/orders_config.rb
class OrdersConfig < Anyway::Config
  include Docuconf::Anyway
  env_prefix "" # read PORT, DATABASE_URL, ... (the default prefix would be ORDERS_)

  attr_config :database_url,
    port: 8080, log_level: "info", allowed_origins: ["http://localhost:3000"],
    request_timeout: "30s", worker_count: 4
  required :database_url

  describe :database_url, "Postgres connection string", type: :url, schemes: %w[postgres], secret: true
  describe :port, "HTTP listen port", min: 1, max: 65_535
  describe :log_level, "Minimum log level", values: %w[debug info warn error]
  describe :allowed_origins, "CORS origins allowed to call the API", min_items: 1
  describe :request_timeout, "Time allowed to handle one request", min: "1s", max: "5m"
  describe :worker_count, "Background workers", min: 1, max: 64
end
```

Types come from the default (`8080` is an `int`, an Array is a `list`), from `coerce_types`, from `type:`, or
from the constraints: `min: "1s"` makes `request_timeout` a duration. A constraint that cannot apply to the
type is an error when the class loads, never silently dropped. In Rails, `bin/rails g docuconf:config orders`
adds the `include` and a `describe` stub per attribute to an existing class.

Values are parsed exactly as the spec says (SPEC §5), whatever anyway_config would accept on its own: a bool is
`true` or `false` in any case (never `1`, `yes` or `t`); an int is decimal digits with an optional sign (`007`
is 7, never octal; `0x10`, `1_000` and `1e3` fail); a float is decimal (no `inf`, `.5` or `5.`); a duration
follows its encoding's grammar; and nothing is trimmed, csv items included (`a, b` is `a` and ` b`). Anything
else is `invalid_type`. The [reference](docs/reference.md#wire-encodings) has every rule.

### Key sets

A key set holds secret keys that are all valid at once, so one can be rotated without an outage: webhook
signatures, inbound API keys, HMAC-signed tokens. It is always secret, and travels as `old,new` during a
rotation:

```ruby
  attr_config :webhook_keys
  describe :webhook_keys, "Keys that verify webhook signatures", type: :key_set,
    key_min_length: 32, key_max_length: 256 # 1 to 2 keys by default: min_keys:, max_keys:

# In the webhook handler: tries every key, without stopping at the first match.
ok = CONFIG.webhook_keys.verify do |key|
  OpenSSL.secure_compare(OpenSSL::HMAC.hexdigest("SHA256", key, body), signature)
end
CONFIG.webhook_keys.contains?(presented_key) # constant time
CONFIG.webhook_keys.keys                     # => in the platform's order
```

A `Docuconf::Anyway::KeySet` prints as `[FILTERED]`. Too few or too many keys is `too_few_items` or
`too_many_items`; a key outside its length bounds, or an empty one (a stray comma), is `out_of_range`, and no
error shows a key. An empty key is reported by its 1-based position: `old,` gives `key 2 is empty`. The generated docs print the rotation steps.

### Descriptions and details

`describe`'s text is the contract's `description`: one line, at least 5 characters. Longer documentation, why
the setting exists and when to change it, goes in `details` (CommonMark, at most 4000 characters). Write it as
the YARD comment directly above `describe` (or above a file macro such as `tls_file`), or pass `details:`:

```ruby
  # How long the server works on one request before it gives up.
  #
  # Raise it for clients that upload large batches. Keep it below the load
  # balancer's idle timeout, or the client sees a reset rather than a +504+.
  describe :request_timeout, "Time allowed to handle one request", min: "1s", max: "5m"

  describe :worker_count, "Background workers", min: 1, max: 64, details: "One per CPU core is a good start."
```

YARD and RDoc markup becomes CommonMark: `{Klass#method}` links and `+code+` become code spans, `= Heading`
a heading, `@example` a fenced code block, `@note` and `@see` sentences; other tags (`@param`, `@return`...) are
dropped. A comment separated from `describe` by a blank line is not read. Export fails when a description is
missing or too short, or when details are blank or longer than 4000 characters. Details are for docs only and
never read at runtime. `docuconf docs` in the [docuconf CLI](https://github.com/docuconf/docuconf-go) generates
`CONFIG.md` and `CONFIG.agents.md` from the exported contract.

## Run

Load the config once at boot:

<!-- readme: boot -->
```ruby
# app.rb (in Rails, the Railtie does this for you: see below)
CONFIG = OrdersConfig.load!

CONFIG.port            # => 8080 (Integer)
CONFIG.allowed_origins # => ["http://localhost:3000"]
CONFIG.request_timeout # => 30 seconds (ActiveSupport::Duration; 30.0 Float seconds without ActiveSupport)
puts "listening on #{CONFIG.port}, timeout #{Docuconf::Anyway.format_duration(CONFIG.request_timeout)}"
```

`load!` returns the config or, if anything is wrong, prints every problem, writes them to
`/dev/termination-log` (so `kubectl describe pod` shows them) and exits 1, without a backtrace.
`OrdersConfig.new` raises `Docuconf::Anyway::ValidationError` instead, a subclass of anyway_config's own.

### Using a watched value

A file input declared `reload: :watch` (`tls_file :serving_tls, path: "/etc/orders/tls", reload: :watch`) is
re-read when Kubernetes updates it: a background thread polls it every `DOCUCONF_WATCH_INTERVAL` seconds (2 by
default), and a new value that passes the boot checks replaces the old one. One that fails is logged and the
old value kept. Anything you build once from the value at boot (a TLS context, an HTTP client, a pool) never
sees the new one, so the certificate it holds eventually expires. Either read the value on every use, or
rebuild what you made from it in an on-change hook:

```ruby
# A TLS server: build the context for each handshake from the current certificate.
ctx = OpenSSL::SSL::SSLContext.new
ctx.servername_cb = ->(_socket, _hostname) { CONFIG.serving_tls.ssl_context }

# An HTTP client: rebuild it when the CA bundle changes.
build_client = ->(ca) { Net::HTTP.new("partner.internal", 443).tap { |h| h.use_ssl = true; h.cert_store = ca.store } }
partner = build_client.(CONFIG.upstream_ca)
subscription = CONFIG.on_file_change(:upstream_ca) { |ca| partner = build_client.(ca) }
subscription.unsubscribe # when the client is gone
```

Hooks run on the watcher thread, with the new value, after it has replaced the old one, and never for a
rejected change. You can register several; one that raises is logged by input name and error class (never its
message, which could quote the value) and the others and the reload go ahead. `on_overlay_change { |config| }`
does the same for a watched overlay.

`CONFIG.docuconf_reload_status(:upstream_ca)` returns a `Docuconf::Anyway::ReloadStatus` for a health check or a
metric: `generation` (1 after boot, plus one per accepted reload), `last_reload` (the `Time` of the last
accepted reload, or `nil`) and `last_rejected` (the last change that failed its checks, as `time`, `input` and
`codes`, never the content; cleared by a later accepted change). Overlays are keyed `:"overlay:<name>"`; with no
argument it returns every watched input's status.

A watched keystore is reopened with the password read at boot: the environment does not change in a running
process, so a reload never reads it again, and a keystore that no longer opens with that password is rejected
(`keystore_unreadable`) and the old one kept. Rotating a keystore's password needs a rollout.

## See an error

<!-- readme: error -->
```console
$ PORT=0 DATABSE_URL=postgres://localhost/orders ruby app.rb
docuconf: DATABSE_URL is set but not declared; did you mean DATABASE_URL?
docuconf: 2 configuration problems:
  - DATABASE_URL [missing_required]: required, and not set: set DATABASE_URL in the environment (a secret cannot come from a file)
  - PORT [out_of_range]: 0 is below min 1
```

Each line names the variable and a stable code (the full list is in the [reference](docs/reference.md#error-codes)).
A secret's value never appears: not in errors, not in `#inspect` or `pp`, and in Rails not in request logs.

## Testing your config

`OrdersConfig.from_env(hash)` loads from that hash instead of `ENV`: it neither reads nor changes the process
environment, starts no file-watcher thread and writes no termination log. `file_root:` points absolute file
paths at a fixture directory. With RSpec:

<!-- readme: spec -->
```ruby
# spec/configs/orders_config_spec.rb
RSpec.describe OrdersConfig do
  let(:env) { {"DATABASE_URL" => "postgres://localhost/orders_test"} }

  it "loads typed values" do
    config = OrdersConfig.from_env(env.merge("PORT" => "9090", "ALLOWED_ORIGINS" => "https://a.example,https://b.example"))
    expect(config.port).to eq 9090
    expect(config.allowed_origins).to eq %w[https://a.example https://b.example]
  end

  it "reports every problem at once" do
    expect { OrdersConfig.from_env("PORT" => "0") }.to raise_error(Docuconf::Anyway::ValidationError) { |e|
      expect(e.violations.map { |v| [v.input, v.code] })
        .to contain_exactly(["DATABASE_URL", :missing_required], ["PORT", :out_of_range])
    }
  end
end
```

anyway_config's own helpers work too (`require "anyway/testing"`, `with_env("PORT" => "0") { ... }`), but they
change `ENV`. If a test loads a class with `reload: :watch` inputs through `.new`, set
`Docuconf::Anyway.watch_files = false` in `spec_helper.rb`.

## Export the contract

<!-- readme: export -->
```sh
bundle exec docuconf export --name orders-api --out contract.cue config/configs/orders_config.rb
```

In Rails:

<!-- readme: rails-export -->
```sh
bin/rails docuconf:export NAME=orders-api OUT=contract.cue APP_VERSION=$(git rev-parse HEAD)
```

Export needs no environment or files: classes are loaded, not instantiated. The result does not depend on
`RAILS_ENV`. Commit `contract.cue`, and fail CI when it is stale:

<!-- readme: check -->
```sh
bundle exec docuconf export --name orders-api --out contract.cue --check config/configs/orders_config.rb
```

Export exits 1 when the files define no config class, so a wrong glob cannot ship an empty contract.
Options (`--package`, `--class`, `--profile`, `--no-profiles`, ...) are in the
[reference](docs/reference.md#export-options).

## Deploy

The app ships `contract.cue`, and the platform checks its inputs against it before anything reaches the
cluster: `docuconf vet` reports every bad or missing value, and `docuconf render` turns valid inputs into the
pod's env in the encodings the contract names (`REQUEST_TIMEOUT: "90s"` becomes `PT90S`). A Helm-based
platform can use the [docuconf Helm chart](https://github.com/docuconf/docuconf-go/tree/main/helm). In the pod,
`load!` (or the Railtie) is the last line of defence.

## Rails

The Railtie validates every docuconf class in `config/configs` and `app/configs` after the app initializes:

- **Server, runner, jobs, tests**: a misconfigured app prints the problems and exits 1, without a backtrace.
- **Tooling** (`rails console`, `generate`, `destroy`, `routes`, `db:*`, ...): the problems are printed as a
  warning and the command carries on, so you can still fix the app.
- **Build tasks** (`assets:precompile`, `docuconf:*`), `SECRET_KEY_BASE_DUMMY`, `ANYWAY_SUPPRESS_VALIDATIONS`
  and `DOCUCONF_SKIP_VALIDATION=1` skip validation.

<!-- readme: rails-config -->
```ruby
# config/application.rb
config.docuconf.validate_on_boot = false            # turn boot validation off
config.docuconf.raise_on_boot = true                # raise ValidationError instead of exiting
config.docuconf.default_profile = "production"      # your image sets RAILS_ENV=production
config.docuconf.export_profiles = %w[production staging] # YAML sections to export
```

- **YAML**: `production:` and `staging:` sections of `config/orders.yml` are exported as profile defaults.
  `development:` and `test:` are not deployed, so the export ignores them: a local database URL there is fine,
  even for a secret.
- **`required ..., env: "production"`** is exported as required, whatever `RAILS_ENV` the export runs in.
- **Credentials** are not set by the platform: `exclude :secret_key_base` leaves an attribute out of the
  contract. anyway_config still loads it.
- **Secrets** are added to `filter_parameters`.
- **Puma cluster mode** with `preload_app!`: `reload: :watch` inputs keep reloading in every worker; docuconf
  restarts its watcher threads after `fork`.
- **Rake tasks**: `docuconf:export` (with `NAME`, `OUT`, `APP_VERSION`, `PACKAGE`, `CLASS`, `PROFILES`,
  `NO_PROFILES=1`, `DEFAULT_PROFILE`, `CHECK=1`) and `docuconf:check`.
- **Generator**: `bin/rails g docuconf:config orders [param ...]` adds the `include` and a `describe` stub per
  attribute, creating the class if it does not exist. The stubs are empty, so boot fails until you describe
  each one.

## Troubleshooting

- **`describe needs include Docuconf::Anyway`**: the class lacks the `include`. (Without this check, RSpec's
  global `describe` would quietly turn the line into a test group.)
- **`min applies to int, float or duration variables, but PORT is a string`**: the type came from a String
  default or a coercion. Add `type: :int` to `describe`, or use an Integer default.
- **`"90s" is not an ISO 8601 duration`**: at boot both `PT90S` and `90s` work; something else was set.
  The contract declares ISO 8601, which is what the platform renders.
- **`a secret must not have a value in the production section of config/orders.yml`**: it would ship in the
  image. Set it in the environment.
- **`no config classes found`**: pass the files that define the classes (`config/configs/*.rb`), or use
  `rails docuconf:export`, which loads them.
- **`docuconf: RAILS_ENV defaults to development, which has no exported profile`**: set
  `config.docuconf.default_profile = "production"` if the image sets `RAILS_ENV=production`.

Everything else (types, encodings, YAML and precedence, overlays, injected secrets, file inputs, contract-first
mode, error codes, environment variables) is in the [reference](docs/reference.md).

## Development

```sh
bundle config set --local with rails   # optional: Railtie specs and ActiveSupport::Duration
bundle install
bundle exec rspec
```

`spec/readme_spec.rb` runs the snippets in this README: the declaration, `load!`, the error output, the RSpec
example and the export command.

The export spec runs `cue vet -c` on the golden contract against the meta-schema in a checkout of
[docuconf-go](https://github.com/docuconf/docuconf-go) (default `../docuconf-go/spec/cue`, or
`DOCUCONF_SPEC_CUE`), using `cue` from `$CUE`, `~/go/bin/cue` or `PATH`. It is skipped when either is missing,
unless `DOCUCONF_REQUIRE_VET=1`. Regenerate the golden file with `UPDATE_GOLDEN=1 bundle exec rspec`.

### Conformance

`spec/conformance_spec.rb` runs the shared conformance suite (SPEC §12): every case in docuconf-go's
`conformance/cases.json`, through contract-first mode, one example per case named by its `id`. It reads the file
from `DOCUCONF_CONFORMANCE`, falling back to `../docuconf-go/conformance/cases.json`, and skips when the file is
missing, unless `DOCUCONF_REQUIRE_CONFORMANCE=1` (as in CI):

```sh
DOCUCONF_CONFORMANCE=../docuconf-go/conformance/cases.json DOCUCONF_REQUIRE_CONFORMANCE=1 \
  bundle exec rspec spec/conformance_spec.rb
```

No capability tags are skipped, and none may be: the runner keeps an allow-list of the tags this SDK supports
(`int64`, `json-schema`, `key-set`, `deprecated`, `strict-parsing`, `files`, `profiles`, `overlays`), skips a
case with any other tag rather than run it, and fails when anything was skipped. Ruby's `Integer` holds every
64-bit value, `json` values are validated against their JSON Schema, and contract-first mode reads key sets,
deprecated inputs, file inputs (TOML through the `tomlrb` gem; PKCS#12 keystores through Ruby's OpenSSL),
profiles and overlays, with the strict parsing rules. Each case runs with its files written under a fresh
`DOCUCONF_FILE_ROOT`.

`spec/export_fixture_spec.rb` declares docuconf-go's shared export fixture (`conformance/export/fixture.yaml`)
in [`spec/fixtures/export_fixture.rb`](spec/fixtures/export_fixture.rb), exports it and compares it with
`conformance/export/golden.cue` using `docuconf conformance export`, from `DOCUCONF_CLI` or built with Go from
`DOCUCONF_GO_DIR`. `spec/golden/gateway.cue` stays as this SDK's own golden file: it also covers YAML
profiles and overlays, which the shared fixture leaves out.

`scripts/conformance.sh` runs these with the specs that `cue vet` exported contracts:

```sh
DOCUCONF_GO_DIR=../docuconf-go scripts/conformance.sh
```

Releases are published to RubyGems from CI with trusted publishing; see [RELEASING.md](RELEASING.md).

## Licence

[MIT](LICENSE).
