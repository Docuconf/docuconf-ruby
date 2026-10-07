# docuconf-anyway reference

The [README](../README.md) walks through install, declare, run, test, export and deploy. This page is the
reference behind it.

- [Export options](#export-options)
- [Declaring variables](#declaring-variables)
- [YAML, credentials and precedence](#yaml-credentials-and-precedence)
- [Config-file overlays](#config-file-overlays)
- [Injected secrets](#injected-secrets)
- [File inputs](#file-inputs)
- [Contract-first mode](#contract-first-mode)
- [Error codes](#error-codes)
- [Kubernetes and local development](#kubernetes-and-local-development)

## Export options

`bundle exec docuconf export` takes:

| Option | |
|---|---|
| `--name`, `-n` | Service name (a DNS label). Required. |
| `--out`, `-o` | File to write. Default: stdout. |
| `--app-version` | `metadata.appVersion`, such as the git SHA. |
| `--package` | CUE package name. Default: the name with `-` replaced by `_`. |
| `--class`, `-c` | Export only these classes (repeatable). Default: every loaded docuconf class. |
| `--root` | Directory `config/<name>.yml` is read from. Default: the working directory. |
| `--no-profiles` | Do not read YAML files. |
| `--profile` | Export this YAML section as a profile (repeatable). Default: every section except `development` and `test`. |
| `--selector`, `--default-profile` | See [YAML](#yaml-credentials-and-precedence). Defaults: `RAILS_ENV`, `development`. |
| `--check` | With `--out`: write nothing, exit 1 if the file is missing or out of date. For CI. |
| `--allow-empty` | Export a contract with no variables when the files define no config class (otherwise exit 1). |

`rails docuconf:export` takes the same options as environment variables: `NAME`, `OUT`, `APP_VERSION`,
`PACKAGE`, `CLASS=A,B`, `PROFILES=production,staging`, `NO_PROFILES=1`, `DEFAULT_PROFILE`, `CHECK=1` and
`ALLOW_EMPTY=1`. `config.docuconf.export_profiles` and `config.docuconf.default_profile` set the defaults.

The contract never depends on the `RAILS_ENV` the export runs in.

## Declaring variables

Each `attr_config` attribute is one variable, named the way anyway_config reads it: `env_prefix` (by
default the upcased `config_name`) + `_` + the upcased attribute, so `:port` in `config_name :billing` is
`BILLING_PORT`. Every attribute needs a `describe` (at least 5 characters) or an `exclude`.

| Contract type | anyway_config declaration | Value |
|---|---|---|
| `string` | `coerce_types x: :string`, or a String/nil default | `String` |
| `int` | `:integer`, an Integer default, or Integer `min:`/`max:` | `Integer` |
| `float` | `:float`, a Float default, or Float `min:`/`max:` | `Float` |
| `bool` | `:boolean`, or a `true`/`false` default | `true`/`false` |
| `duration` | `:duration` (added by docuconf), or duration `min:`/`max:` (`"1s"`, `"PT5M"`) | `ActiveSupport::Duration`, or `Float` seconds without ActiveSupport |
| `url` | `:uri`, `describe x, "...", type: :url`, or `schemes:` | `URI` / `String` |
| `enum` | `describe x, "...", values: [...]` | `String` |
| `list` | `{type: :string \| :integer, array: true}`, an Array default, or `min_items:`/`max_items:` (`item_min:`/`item_max:` for ints) | `Array` |
| `json` | `:json` (added by docuconf), or `type: :json`; `schema:` as for config files | parsed JSON |

- **Metadata**: `describe :attr, "description", group:, examples:, config_key:, deprecated:, type:`, plus any
  constraint. `constrain :attr, ...` adds constraints alone: `min`, `max` (numbers, or durations in Go or
  ISO 8601 syntax), `min_length`, `max_length`, `pattern`, `values`, `schemes`, `min_items`, `max_items`,
  `item_min`/`item_max` (each item of an int list; exported as `itemMin`/`itemMax`, and an item outside them is
  `out_of_range`), `schema`/`json_schema` (json only).
- **Type from constraints**: the order is `type:`, then `coerce_types`, then a typed default, then the
  constraints. So `attr_config :port` with `describe :port, "...", min: 1, max: 65_535` is an `int`, and so is
  `port: "8080"` (a String default that reads as the inferred type). A constraint that cannot apply to the
  resolved type (`min:` on a bool, `min_items:` on a string) is a `DeclarationError`, never silently dropped.
- **Integer range**: Ruby's `Integer` holds any 64-bit value, so there is no narrower item or field type whose
  range docuconf must export; values outside the 64-bit range are `out_of_range`.
- **Secrets**: `secret: true` in `describe`, or `secret :attr, ...`. A secret cannot have a default, examples,
  or a value in an exported YAML section. Its value never appears in errors (including errors your own
  `on_load` checks raise), in `#inspect` or `pp`, and in Rails, `filter_parameters` filters it.
- **Required**: anyway_config's `required`. An attribute with a default (or a value in an always-loaded
  YAML file) is exported as optional with that default. `required :x, env: "production"` is exported as
  required whatever `RAILS_ENV` the export runs in: a variable required in any environment other than
  `development` and `test` is required in the contract. At boot, anyway_config's environment filter applies.
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

Platform authors still write `"90s"` and `["a", "b"]`; the renderer converts. At boot a declared duration
also accepts Go syntax (`REQUEST_TIMEOUT=90s` in a `.env` file), as its defaults do.

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
- Deployable environment sections (`production:`, `staging:`, ...) become `profiles.defaults`, selected by
  `RAILS_ENV` (default `development`, as in Rails; set `config.docuconf.default_profile = "production"` or
  `--default-profile` if your image sets `RAILS_ENV=production`). If no declared variable is named
  `RAILS_ENV`, one is added to the contract, since the meta-schema requires the selector to be declared.
- `development` and `test` sections are not deployed, so they are left out, with a note on stderr. A local
  database URL there is fine, even for a secret. Choose the sections with `--profile` / `PROFILES=` /
  `config.docuconf.export_profiles`.
- Values are checked against each variable's constraints, and a secret with a value in an exported section is
  an error.
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

```ruby
class BillingConfig < Anyway::Config
  include Docuconf::Anyway

  config_name :billing
  attr_config port: 8080
  describe :port, "HTTP listen port", min: 1, max: 65_535

  tls_file :serving_tls,
    path: "/etc/billing/tls", required: true, reload: :watch,
    description: "Certificate the API serves HTTPS with",
    dns_names: %w[billing.internal], min_remaining: "168h"

  config_file :plans,
    format: :yaml, path: "/etc/billing/plans/plans.yaml", required: true,
    description: "Price plans offered at checkout",
    schema: {plans: Docuconf::S.array({id: Docuconf::S.string(pattern: "^[a-z-]+$"), cents: Docuconf::S.integer(min: 0),
                                       "trial_days?": Integer}, min_items: 1)}
end

config = BillingConfig.new
config.serving_tls # => Docuconf::Anyway::TLSMaterial (certificate, key, chain, #ssl_context)
config.plans       # => {"plans" => [{"id" => "basic", "cents" => 900}]}, parsed, checked, frozen
```

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
`Docuconf::S` (short for `Docuconf::Anyway::Schema`) helpers for constraints (`S.string(pattern:, min_length:)`, `S.integer(min:, max:)`,
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
Threads do not survive `fork`, so docuconf restarts the watchers in every forked child (`Process._fork`): Puma
cluster workers with `preload_app!`, Unicorn and Resque workers keep reloading. For a fork docuconf cannot see,
call `Docuconf::Anyway.restart_watchers!` in the child.


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
`nil`, and durations are `ActiveSupport::Duration` (`Float` seconds without ActiveSupport). File inputs and overlays in
the contract are not checked in this mode.


## Error codes

`missing_required`, `invalid_type`, `out_of_range`, `pattern_mismatch`, `not_in_enum`, `invalid_scheme`,
`too_few_items`, `too_many_items`, `file_missing`, `file_unreadable`, `file_too_large`, `file_malformed`,
`schema_mismatch`, `certificate_invalid`, `certificate_expiring`, `certificate_name_mismatch`, `key_mismatch`,
`keystore_unreadable`.

`ValidationError#violations` holds `Violation`s with `input`, `kind` (`:var`, `:file` or `:overlay`), `code` and
`message`.


## Kubernetes and local development

| Variable | Effect |
|---|---|
| `DOCUCONF_FILE_ROOT` | Prefix for absolute file and overlay paths (including paths from `path_env`), so `/etc/billing/tls` is read from `$DOCUCONF_FILE_ROOT/etc/billing/tls`. For local development and tests. |
| `DOCUCONF_TERMINATION_LOG` | Where to write violations. By default they go to `/dev/termination-log` when it exists, so `kubectl describe pod` shows why the pod failed. |
| `DOCUCONF_SKIP_VALIDATION` | `1` skips boot validation (file inputs are still loaded when they can be). |
| `DOCUCONF_WATCH_INTERVAL` | Seconds between polls for `reload: :watch` inputs and overlays. |

