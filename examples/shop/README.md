# Example: shop

One program that runs as two workloads, a `web` server and a queue `worker`, configured by a contract written by
hand and loaded in [contract-first mode](../../docs/reference.md#contract-first-mode). It shows three parts of the
spec:

- **roles** (SPEC §4.9): `DOCUCONF_ROLE` picks the role, and an input marked with roles is required only in those.
  The web server needs `ALLOWED_ORIGINS`, the worker needs `QUEUES`, and neither needs the other's.
- **`requiredIf`** (SPEC §4.2.1): `LOG_SCHEMA_URL` is required while `LOG_FORMAT` is `json`, and the
  `webhook-signing-key` file while `WEBHOOKS_ENABLED` is `true` (in the worker; the web server never reads it).
- **an included fragment** (SPEC §4.8): the contract includes `otel@1`, whose `OTEL_*` variables are inline in
  `vars` and checked at boot like the app's own.

It has no server, database or queue: [`shop.rb`](shop.rb) loads its configuration, prints one line and exits 0, or
lists every problem and exits 1.

```ruby
CONTRACT = Docuconf::Anyway::Contract.parse(File.read("contract.json"))
config = Docuconf::Anyway.exit_on_failure { CONTRACT.load(ENV, watch: false) }
```

The Ruby SDK has no declaration API for roles, `requiredIf` or fragments yet, so the contract is written by hand:

- [`contract.json`](contract.json) is the contract, the same in every docuconf SDK's shop example; the app reads it at
  start.
- [`contract.cue`](contract.cue) is the same data in CUE, for `cue vet` and the platform. It is generated:
  `./contract-cue.sh` rewrites it from `contract.json`, and CI fails if it is out of date.

| Input | Type | Rules |
|---|---|---|
| `DOCUCONF_ROLE` | enum | `web` or `worker`; required |
| `DATABASE_URL` | url | secret, required, scheme `postgres` or `postgresql` |
| `PORT` | int | `web` only; 1–65535, default `8080` |
| `ALLOWED_ORIGINS` | list of strings, comma-separated | `web` only; required |
| `QUEUES` | list of strings, comma-separated | `worker` only; required |
| `WEBHOOKS_ENABLED` | bool | `worker` only; default `false` |
| `LOG_FORMAT` | enum | `text` or `json`; default `text` |
| `LOG_SCHEMA_URL` | url | scheme `https`; required when `LOG_FORMAT` is `json` |
| `OTEL_*` | from `otel@1` | optional; `OTEL_EXPORTER_OTLP_PROTOCOL` is one of `grpc`, `http/protobuf`, `http/json` |
| `webhook-signing-key` (file) | text | `worker` only; secret, at `/etc/shop/webhooks/signing.key`, at least 32 characters; required when `WEBHOOKS_ENABLED` is `true` |

Lists are comma-separated on the wire, the contract's default encoding. Files are read under `DOCUCONF_FILE_ROOT`
when it is set. The [`Gemfile`](Gemfile) uses the SDK in this repository (`path: "../.."`).

## Run it

```console
$ cd examples/shop
$ bundle install
$ export DATABASE_URL=postgres://shop@db:5432/shop
$ DOCUCONF_ROLE=web ALLOWED_ORIGINS=https://shop.example bundle exec ruby shop.rb
shop web: port 8080, origins https://shop.example
$ DOCUCONF_ROLE=worker QUEUES=default,mail bundle exec ruby shop.rb
shop worker: queues default,mail, webhooks off
```

The worker sends webhooks only with a signing key. With `WEBHOOKS_ENABLED=true`, JSON logs and an unknown OTLP
protocol, it refuses to start, exits 1 and lists every problem, never printing `DATABASE_URL`:

```console
$ DOCUCONF_ROLE=worker QUEUES=default WEBHOOKS_ENABLED=true LOG_FORMAT=json \
    OTEL_EXPORTER_OTLP_PROTOCOL=carrier-pigeon bundle exec ruby shop.rb
docuconf: 3 configuration problems:
  - OTEL_EXPORTER_OTLP_PROTOCOL [not_in_enum]: "carrier-pigeon" is not one of grpc, http/protobuf, http/json
  - LOG_SCHEMA_URL [missing_required]: is required when LOG_FORMAT is "json"
  - webhook-signing-key [file_missing]: /etc/shop/webhooks/signing.key does not exist, and is required when WEBHOOKS_ENABLED is true
$ echo $?
1
```

## Test matrix

[`test/shop_test.rb`](test/shop_test.rb) runs every case (`bundle exec ruby test/shop_test.rb`), each from
`DATABASE_URL=postgres://shop@db:5432/shop` with a fresh, empty `DOCUCONF_FILE_ROOT`. A failing case must report
exactly the problems listed, exit 1 and not print `DATABASE_URL`.

| # | Env (plus the base) | Expected |
|---|---|---|
| 1 | `DOCUCONF_ROLE=web ALLOWED_ORIGINS=https://shop.example` | ok: `shop web: port 8080, origins https://shop.example` |
| 2 | `DOCUCONF_ROLE=worker QUEUES=default,mail` | ok: `shop worker: queues default,mail, webhooks off`; the worker needs no `ALLOWED_ORIGINS` |
| 3 | `DOCUCONF_ROLE=web` | `ALLOWED_ORIGINS` `missing_required` |
| 4 | `QUEUES=default` (no role) | `DOCUCONF_ROLE` `missing_required`, and nothing else |
| 5 | `DOCUCONF_ROLE=cron` | `DOCUCONF_ROLE` `not_in_enum`, and nothing else |
| 6 | `DOCUCONF_ROLE=worker QUEUES=default LOG_FORMAT=json` | `LOG_SCHEMA_URL` `missing_required`: `is required when LOG_FORMAT is "json"` |
| 7 | as 6, plus `LOG_SCHEMA_URL=https://logs.example/v1.json` | ok |
| 8 | `DOCUCONF_ROLE=worker QUEUES=default WEBHOOKS_ENABLED=true`, no key file | `webhook-signing-key` `file_missing`: `..., and is required when WEBHOOKS_ENABLED is true` |
| 9 | as 8, with a 40-character key at `etc/shop/webhooks/signing.key` under the root | ok: `shop worker: queues default, webhooks on` |
| 10 | `DOCUCONF_ROLE=web ALLOWED_ORIGINS=https://shop.example WEBHOOKS_ENABLED=true` | ok: the key file belongs to the worker |
| 11 | `DOCUCONF_ROLE=web ALLOWED_ORIGINS=https://shop.example OTEL_EXPORTER_OTLP_PROTOCOL=carrier-pigeon` | `OTEL_EXPORTER_OTLP_PROTOCOL` `not_in_enum`: fragment variables are checked at boot |

[`smoke.sh`](smoke.sh) runs the real process for cases 1, 2 and 6 and checks stdout and the exit code; CI runs
both on every push.

## Generated docs

[`CONFIG.md`](CONFIG.md) (for developers), [`CONFIG.agents.md`](CONFIG.agents.md) (for AI agents) and `docs.json`
(the docs model) are generated from the contract by the `docuconf` CLI from
[docuconf-go](https://github.com/docuconf/docuconf-go); never edit them by hand. After changing `contract.json`,
regenerate `contract.cue` and the docs (CI runs each with `--check` in place of `-o`):

```console
$ ./contract-cue.sh
$ docuconf docs contract.json -o CONFIG.md
$ docuconf docs contract.json --format agents -o CONFIG.agents.md
$ docuconf docs contract.json --format model -o docs.json
```
