# docuconf-anyway

The Ruby SDK for [docuconf](https://github.com/docuconf): typed configuration contracts between an
application and the Kubernetes platform that runs it.

It extends [anyway_config](https://github.com/palkan/anyway_config) rather than replacing it. You keep your
`Anyway::Config` classes, with `attr_config`, `required`, `coerce_types`, `config_name` and `env_prefix`,
and anyway_config keeps loading YAML, credentials and the environment. docuconf adds:

1. **Declaration metadata** anyway_config has no field for: descriptions, `secret`, constraints (ranges,
   lengths, RE2 patterns, enum values, URL schemes, list bounds), a `:duration` type, and file inputs
   (config files, TLS key pairs, CA bundles, keystores, text and binary files).
2. **Boot validation.** Every problem with variables *and* mounted files is reported at once, each with a
   stable error code. Secret values are never printed.
3. **Contract export.** `docuconf export` (or `rails docuconf:export`) turns the same declaration into a
   `contract.cue`, so the platform can reject bad configuration before it deploys.

> Status: v0.1, implementing [spec v1alpha1](https://github.com/docuconf/docuconf-go/blob/main/spec/SPEC.md).
> Expect breaking changes until v1.

## Install

```ruby
# Gemfile
gem "docuconf-anyway"
```

Requires Ruby 3.2+ and anyway_config 2.6+. The require path is `docuconf/anyway` (Bundler requires it for
you; the Railtie loads automatically in Rails).

## Example

```ruby
# config/configs/billing_config.rb
class BillingConfig < Anyway::Config
  include Docuconf::Anyway
  S = Docuconf::Anyway::Schema

  config_name :billing
  attr_config :database_url, :secret_key_base,
    port: 8080, log_level: "info", request_timeout: "PT30S", allowed_origins: []
  required :database_url
  coerce_types request_timeout: :duration, allowed_origins: {type: :string, array: true}

  describe :database_url, "Primary Postgres connection string", type: :url, schemes: %w[postgres postgresql]
  secret :database_url
  describe :port, "HTTP listen port", min: 1, max: 65_535
  describe :log_level, "Minimum log level", values: %w[debug info warn error]
  describe :request_timeout, "Upstream request timeout", max: "5m"
  describe :allowed_origins, "CORS origins allowed to call the API", max_items: 10
  exclude :secret_key_base # from Rails credentials: not part of the platform contract

  tls_file :serving_tls,
    path: "/etc/billing/tls", required: true, reload: :watch,
    description: "Certificate the API serves HTTPS with",
    dns_names: %w[billing.internal], min_remaining: "168h"

  config_file :plans,
    format: :yaml, path: "/etc/billing/plans/plans.yaml", required: true,
    description: "Price plans offered at checkout",
    schema: {plans: S.array({id: S.string(pattern: "^[a-z-]+$"), cents: S.integer(min: 0), "trial_days?": Integer}, min_items: 1)}
end
```

```ruby
config = BillingConfig.new
config.port               # => 8080 (Integer), from BILLING_PORT
config.request_timeout    # => 30.seconds (ActiveSupport::Duration; whole seconds without ActiveSupport)
config.allowed_origins    # => ["https://a.example.com"], from BILLING_ALLOWED_ORIGINS=https://a.example.com
config.serving_tls        # => Docuconf::Anyway::TLSMaterial (certificate, key, chain, #ssl_context)
config.plans              # => {"plans" => [{"id" => "basic", "cents" => 900}]}, parsed, checked, frozen
```

If anything is wrong, loading the config raises `Docuconf::Anyway::ValidationError` (a subclass of
`Anyway::Config::ValidationError`) listing every problem:

```
docuconf: 3 configuration problems:
  - BILLING_DATABASE_URL [invalid_scheme]: URL scheme is not one of postgres, postgresql
  - BILLING_PORT [out_of_range]: 70000 is above max 65535
  - serving-tls [certificate_name_mismatch]: certificate does not cover billing.internal
```

The secret's value (and even its scheme) is left out of the message.

## Export the contract

In Rails:

```sh
bin/rails docuconf:export OUT=contract.cue                  # NAME defaults to the app name
bin/rails docuconf:export NAME=billing-api APP_VERSION=$(git rev-parse HEAD) OUT=contract.cue
```

Without Rails:

```sh
bundle exec docuconf export --name billing-api --out contract.cue config/configs/billing_config.rb
```

| Option | |
|---|---|
| `--name`, `-n` | Service name (a DNS label). Required. |
| `--out`, `-o` | File to write. Default: stdout. |
| `--app-version` | `metadata.appVersion`, such as the git SHA. |
| `--package` | CUE package name. Default: the name with `-` replaced by `_`. |
| `--class`, `-c` | Export only these classes (repeatable). Default: every loaded docuconf class. |
| `--root` | Directory `config/<name>.yml` is read from. Default: the working directory. |
| `--no-profiles` | Do not read YAML files. |
| `--selector`, `--default-profile` | See below. Defaults: `RAILS_ENV`, `development`. |

Export runs in **export mode**: classes are loaded but not instantiated, so no real environment or files
are needed. `docuconf check FILE...` (or `rails docuconf:check`) validates the current environment instead.

The output is plain CUE data that unifies with the meta-schema's `contract.#Contract`, with variables and
files sorted by name (a full example: [`spec/golden/gateway.cue`](spec/golden/gateway.cue)):

```cue
// Code generated by docuconf. DO NOT EDIT.
package billing_api

import "docuconf.dev/contract"

contract.#Contract & {
	apiVersion: "docuconf.dev/v1alpha1"
	kind:       "ConfigContract"
	metadata: {
		name: "billing-api"
		generator: {
			language: "ruby"
			sdk:      "docuconf-anyway"
			version:  "0.1.0"
		}
	}
	vars: {
		BILLING_PORT: {
			type:        "int"
			description: "HTTP listen port"
			configKey:   "billing.port"
			min:         1
			max:         65535
			default:     8080
		}
		// ...
```

## Declaring variables

Each `attr_config` attribute is one variable, named the way anyway_config reads it: `env_prefix` (by
default the upcased `config_name`) + `_` + the upcased attribute, so `:port` in `config_name :billing` is
`BILLING_PORT`. Every attribute needs a `describe` (at least 5 characters) or an `exclude`.

| Contract type | anyway_config declaration | Value |
|---|---|---|
| `string` | `coerce_types x: :string`, or a String/nil default | `String` |
| `int` | `:integer`, or an Integer default | `Integer` |
| `float` | `:float`, or a Float default | `Float` |
| `bool` | `:boolean`, or a `true`/`false` default | `true`/`false` |
| `duration` | `:duration` (added by docuconf) | `ActiveSupport::Duration`, or seconds without ActiveSupport |
| `url` | `:uri`, or `describe x, "...", type: :url` | `URI` / `String` |
| `enum` | `describe x, "...", values: [...]` | `String` |
| `list` | `{type: :string \| :integer, array: true}`, or an Array default | `Array` |
| `json` | `:json` (added by docuconf), or `type: :json`; `schema:` as for config files | parsed JSON |

- **Metadata**: `describe :attr, "description", group:, examples:, config_key:, deprecated:, type:`, plus any
  constraint. `constrain :attr, ...` adds constraints alone: `min`, `max` (numbers, or durations in Go or
  ISO 8601 syntax), `min_length`, `max_length`, `pattern`, `values`, `schemes`, `min_items`, `max_items`,
  `item_min`/`item_max` (each item of an int list; exported as `itemMin`/`itemMax`, and an item outside them is
  `out_of_range`), `schema`/`json_schema` (json only).
- **Integer range**: Ruby's `Integer` holds any 64-bit value, so there is no narrower item or field type whose
  range docuconf must export; values outside the 64-bit range are `out_of_range`.
- **Secrets**: `secret :attr, ...`. A secret cannot have a default, examples, or a value in a YAML file, and
  its value never appears in errors.
- **Required**: anyway_config's `required`. An attribute with a default (or a value in an always-loaded
  YAML file) is exported as optional with that default.
- **Coercion**: docuconf pins a coercion for every declared attribute you gave none, so anyway_config binds
  exactly the contract type (without one, anyway_config auto-casts, turning `"007"` into `7` and `"a,b"` into
  an array even for a string setting).
- **Patterns** are RE2 and match anywhere in the value; anchor with `^...$`. They are translated for Ruby
  (`^`/`$` mean start/end of text, as in RE2, not of a line), and lookaround, backreferences, atomic groups
  and possessive quantifiers are rejected at definition time.
- **Feature flags**: names starting `FF_`, `FEATURE_`, `FEATURE_FLAG_` or `ENABLE_` produce a warning
  (SPEC §10).
- **Nested settings** (a Hash default or nested `coerce_types`) have no v1alpha1 type: they stay file-only,
  with a warning, and are not exported.

Problems with the declaration itself (missing descriptions, non-RE2 patterns, defaults that break their own
constraints, clashing mounts) raise `Docuconf::Anyway::DeclarationError` on first load and on export.

### Wire encodings

| Type | Encoding in the contract | What the platform renders |
|---|---|---|
| `list` | `csv`, separator `,` | `a,b`, which anyway_config's array coercion splits |
| `duration` | `iso8601` | `PT90S`, which `ActiveSupport::Duration.parse` (or docuconf's parser) reads |

Platform authors still write `"90s"` and `["a", "b"]`; the renderer converts.

Parsing follows SPEC §5, with a strict pre-check before anyway_config's coercion: integers are plain base-10
within 64 bits (`"80a"` is an error, not `80`), floats are finite, booleans are `true`/`false` (anyway's
`yes`/`no`/`1`/`0` also work; anything else is an error rather than `false`), an empty string is *unset* for
every type except `string`, and values are never trimmed. anyway_config's array coercion does trim spaces
around commas in list items.

## YAML, credentials and precedence

anyway_config reads `config/<name>.yml` and, in Rails, credentials, then any declared overlay (see below),
then the environment, which wins. This
matches the spec's precedence (platform variables override files). At export:

- A YAML file without environment sections (or the `default_environmental_key` section) is always loaded:
  its values become `default`s.
- Environment sections (`production:`, `staging:`, ...) become `profiles.defaults`, selected by `RAILS_ENV`
  (default `development`, as in Rails). If no declared variable is named `RAILS_ENV`, one is added to the
  contract, since the meta-schema requires the selector to be declared.
- Values are checked against each variable's constraints, and a secret with a YAML value is an error.
- Rails credentials are not injected by the platform, so attributes that come from them must be
  `exclude`d. Excluded attributes are still loaded by anyway_config, and `required` still applies to them.

## Config-file overlays

A platform can supply settings as a mounted YAML file instead of environment variables (SPEC §4.7). Declare
where the app reads it:

```ruby
class BillingConfig < Anyway::Config
  include Docuconf::Anyway

  config_name :billing
  attr_config port: 8080, log_level: "info"
  describe :port, "HTTP listen port", min: 1, max: 65_535
  describe :log_level, "Minimum log level", values: %w[debug info warn error]

  config_overlay :platform,
    path: "/etc/billing/overlay/billing.yml",
    description: "Settings the platform supplies as a file",
    reload: :watch # or :restart (the default)
end
```

The export adds `overlays: platform: {format: "yaml", path: ..., keySeparator: ".", reload: "watch"}`.
Every variable is exported with a `configKey` of `<config_name>.<attribute>` (`billing.port`), and the
platform writes each value there, nested on `.` and in native YAML types, exactly as anyway_config reads
`config/billing.yml`:

```yaml
billing:
  log_level: warn
  port: 9090
```

- **Precedence:** docuconf registers an anyway_config loader, `:docuconf_overlay`, in `Anyway.loaders` just
  before `:env`: `config/<name>.yml` < Rails credentials < overlay < environment. Declaring an overlay opts in
  to it, so it is loaded even when `configuration_sources` leaves it out.
- **Optional:** a missing file is no values. A file that is not valid YAML is `file_malformed`, and its
  values are checked like any other (`out_of_range`, `not_in_enum`, ...). Secrets in an overlay are ignored
  with a warning: they come from the environment.
- **`reload: :watch`:** the overlay's directory is polled like a watched file input. When it changes, the
  config is loaded again through anyway_config into a new instance and validated; if that passes, its values
  are copied into the running config and `config.on_overlay_change { |config| ... }` listeners run, otherwise
  the problems are logged and the old values kept.
- **Its own directory:** the platform mounts the overlay's directory, hiding what the image has there.
  docuconf rejects reserved directories (`/app`, `/etc`, ...) and directories shared with a file input at
  declaration, and at load an overlay in the app's root or in the directory anyway_config reads
  `config/<name>.yml` from.

## Injected secrets

Platforms often supply secrets at start-up rather than in the pod spec: Bank-Vaults' `vault-env` resolves
values such as `vault:secret/data/billing/db#url`, and wrappers such as `op run` resolve `op://` references,
then start the app with the real values. Nothing changes in your declaration: anyway_config reads the
environment as it is when the process starts, after injection, so injected values are validated like any
other. docuconf never resolves references itself.

If the injector did not run, the app sees the raw reference. A secret whose value still starts with `vault:`,
`op://` or `ref+` is reported as `invalid_type`, naming the variable and the scheme but never the value:

```
BILLING_DATABASE_URL [invalid_type]: holds an unresolved vault: reference; the injector that should resolve it did not run
```

## File inputs

| Macro | Contract type | Accessor returns |
|---|---|---|
| `config_file name, format: :json \| :yaml \| :toml, schema: \| json_schema:, into:` | `config` | parsed, schema-checked data (frozen), or `into` applied to it |
| `tls_file name, dns_names:, key_algorithms:, min_remaining:, require_ca:` | `tls` (a `kubernetes.io/tls` directory) | `TLSMaterial`: `certificate`, `key`, `chain`, `ca_certificates`, PEMs, `#ssl_context` |
| `ca_bundle_file name, min_certificates:` | `caBundle` | `CABundle`: `certificates`, `pem`, `#store` |
| `keystore_file name, format: :pkcs12, password_var:` | `keystore` | `OpenSSL::PKCS12` |
| `text_file name, pattern:, min_length:, max_length:` | `text` | `String` |
| `binary_file name` | `binary` | the resolved path |

Every macro takes `path:`, `description:`, `required:`, `path_env:`, `reload: :restart | :watch`, `max_size:`,
`group:`, `deprecated:` and `name:` (the contract name; default: the accessor with `_` as `-`). Absent optional
inputs are `nil`. `password_var:` is a secret attribute of the same class (a Symbol) or a variable name.

**Schemas come from Ruby types.** `schema:` takes a type spec: `String`, `Integer`, `Float`, `:boolean`, a
Hash for an object with exactly those keys (`"key?"` for optional ones), `[Type]` for an array, and
`Docuconf::Anyway::Schema` helpers for constraints (`S.string(pattern:, min_length:)`, `S.integer(min:, max:)`,
`S.array(of, min_items:)`, `S.enum(...)`, `S.map(of)`, `S.nullable(type)`). Any object responding to
`json_schema` (such as a dry-schema with its `:json_schema` extension) works too, or pass an explicit
`json_schema:`. The boot validator supports the common JSON Schema keywords and rejects others (`$ref`,
`patternProperties`, ...) at definition time rather than ignoring them. `into:` binds the data to your type:
a callable, or a class taking keyword arguments (`Data.define`, `Struct` with `keyword_init`).

Checks at boot (SPEC §11.2 item 7):

- the file exists, is readable and within `max_size` (`file_unreadable` hints at `fsGroup` for root-owned
  secret volumes);
- `config`: parses (a UTF-8 BOM is accepted) and matches the schema. TOML needs the `tomlrb` gem;
- `tls`: `tls.crt` and `tls.key` parse and match (`check_private_key`); the certificate is valid now with at
  least `min_remaining` left, covers every `dns_names` entry (`OpenSSL::SSL.verify_certificate_identity`,
  so a wildcard covers one label), uses an allowed key algorithm, is ordered leaf first, and with
  `require_ca` chains to `ca.crt` (`OpenSSL::X509::Store`);
- `caBundle`: at least `min_certificates` parseable certificates;
- `keystore`: PKCS#12 opens with the password from `password_var` (`OpenSSL::PKCS12`). Ruby has no JKS
  parser, so only a JKS keystore's magic number is checked;
- `text`: `pattern`, `min_length`, `max_length`.

`reload: :watch` inputs are re-read when they change: a background thread polls each input's directory
(Kubernetes swaps a `..data` symlink) every 2 seconds (`DOCUCONF_WATCH_INTERVAL`). A reload that fails its
checks is logged and the previous value kept. React with `config.on_file_change(:serving_tls) { |tls| ... }`.

## Contract-first mode

`Docuconf::Anyway::Contract` validates an environment against a contract with no `Anyway::Config` class, for
teams that write the contract in CUE by hand and export it with `cue export --out json`:

```ruby
contract = Docuconf::Anyway::Contract.parse(File.read("contract.json")) # JSON text or a Hash
values = contract.load(ENV) # => {"PORT" => 8080, "TIMEOUT" => 30.seconds, "ORIGINS" => [...], "DEBUG" => nil}
```

`Docuconf::Anyway.load_contract(json, env: ENV)` does both steps. It reads every wire encoding of SPEC §5: `csv`
lists with any `separator`, `json` lists and `indexed` lists (`NAME__0`, `NAME__1`, ..., numbered from 0 with no gap; a gap is `invalid_type`); `go`, `iso8601`,
`seconds` and `timespan` (`[d.]hh:mm:ss[.fff]`) durations. Values go through the same parsing and checks as the
declaration path, profile defaults apply for the selected profile, and every problem is raised together as a
`ValidationError` (also written to the termination log; pass `termination_log: false` to skip that). A
malformed contract raises `DeclarationError`. Values are keyed by variable name: absent optional variables are
`nil`, and durations are `ActiveSupport::Duration` (seconds without ActiveSupport). File inputs and overlays in
the contract are not checked in this mode.

## Error codes

`missing_required`, `invalid_type`, `out_of_range`, `pattern_mismatch`, `not_in_enum`, `invalid_scheme`,
`too_few_items`, `too_many_items`, `file_missing`, `file_unreadable`, `file_too_large`, `file_malformed`,
`schema_mismatch`, `certificate_invalid`, `certificate_expiring`, `certificate_name_mismatch`, `key_mismatch`,
`keystore_unreadable`.

`ValidationError#violations` holds `Violation`s with `input`, `kind` (`:var`, `:file` or `:overlay`), `code` and
`message`.

## Rails

The Railtie validates every docuconf config class (eager-loading `config/configs` and `app/configs`) after
the app initializes, so a misconfigured pod fails at start with every problem listed. It skips validation for
build-time tasks (`assets:precompile`, `docuconf:*`), when anyway_config suppresses required validations
(`SECRET_KEY_BASE_DUMMY`, `ANYWAY_SUPPRESS_VALIDATIONS`), and when `DOCUCONF_SKIP_VALIDATION=1`. Turn it off
with `config.docuconf.validate_on_boot = false`.

Rake tasks: `docuconf:export` and `docuconf:check`.

## Kubernetes and local development

| Variable | Effect |
|---|---|
| `DOCUCONF_FILE_ROOT` | Prefix for absolute file and overlay paths (including paths from `path_env`), so `/etc/billing/tls` is read from `$DOCUCONF_FILE_ROOT/etc/billing/tls`. For local development and tests. |
| `DOCUCONF_TERMINATION_LOG` | Where to write violations. By default they go to `/dev/termination-log` when it exists, so `kubectl describe pod` shows why the pod failed. |
| `DOCUCONF_SKIP_VALIDATION` | `1` skips boot validation (file inputs are still loaded when they can be). |
| `DOCUCONF_WATCH_INTERVAL` | Seconds between polls for `reload: :watch` inputs and overlays. |

## Development

```sh
bundle config set --local with rails   # optional: Railtie specs and ActiveSupport::Duration
bundle install
bundle exec rspec
```

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

No capability tags are skipped: Ruby's `Integer` holds every 64-bit value (`int64`), and `json` values are
validated against their JSON Schema (`json-schema`).

Releases are published to RubyGems from CI with trusted publishing; see [RELEASING.md](RELEASING.md).

## Licence

[MIT](LICENSE).
