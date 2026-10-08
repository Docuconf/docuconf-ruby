# Example: orders

A tiny Rack service whose configuration is declared with docuconf. It shows the three things the Ruby SDK
gives an app:

- a normal [anyway_config](https://github.com/palkan/anyway_config) class, with docuconf's `describe` and
  `secret` adding descriptions, secrets and constraints ([`config/orders_config.rb`](config/orders_config.rb));
- one check at boot, `OrdersConfig.load!`, that reports every problem at once with stable codes and exits 1
  ([`config.ru`](config.ru));
- a CUE contract exported from the class, for the platform to validate before it deploys
  ([`contract.cue`](contract.cue)).

| Variable | Type | Rules |
|---|---|---|
| `PORT` | int | 1–65535, default `8080` |
| `LOG_LEVEL` | enum | `debug`, `info`, `warn`, `error`; default `info` |
| `DATABASE_URL` | url | secret, required, scheme `postgres`, at most 2048 characters |
| `ALLOWED_ORIGINS` | list of strings, comma-separated | at least 1 item; default `http://localhost:3000` |
| `REQUEST_TIMEOUT` | duration, ISO 8601 (`PT30S`); `30s` also works locally | `1s`–`5m`, default `30s` |
| `WORKER_COUNT` | int | 1–64, default `4` |

The names have no prefix because the class sets `env_prefix ""`. Lists and durations use the encodings
anyway_config parses, and the contract says so, so the platform renders `REQUEST_TIMEOUT: "90s"` as `PT90S`.

The [`Gemfile`](Gemfile) uses the SDK in this repository (`path: "../.."`), not a published version.

## Run it

```console
$ cd examples/orders
$ bundle install
$ DATABASE_URL=postgres://orders:pw@localhost:5432/orders bundle exec ruby server.rb
$ curl localhost:8080/healthz
ok
$ curl localhost:8080/config
{"PORT":8080,"LOG_LEVEL":"info","DATABASE_URL":"***","ALLOWED_ORIGINS":["http://localhost:3000"],"REQUEST_TIMEOUT":"30s","WORKER_COUNT":4}
```

`server.rb` serves [`config.ru`](config.ru) with WEBrick on the configured `PORT`; Puma or `rackup` can serve
`config.ru` as is. `/config` shows the typed values; the secret is always `***`.

## When the configuration is wrong

With `PORT=0` and no `DATABASE_URL`, the service refuses to start, exits 1 and lists every problem, not just
the first:

```console
$ PORT=0 bundle exec ruby server.rb
docuconf: 2 configuration problems:
  - DATABASE_URL [missing_required]: required, and not set: set DATABASE_URL in the environment (a secret cannot come from a file)
  - PORT [out_of_range]: 0 is below min 1
$ echo $?
1
```

[`smoke.sh`](smoke.sh) checks both runs; CI runs it on every push.

## Export the contract

`contract.cue` is generated; never edit it by hand. Re-export it after changing
`config/orders_config.rb`:

```console
$ bundle exec docuconf export --name orders-api --package orders --out contract.cue config/orders_config.rb
```

CI runs the same command with `--check`, which writes nothing and exits 1 if `contract.cue` is out of date.

## Generated docs

[`CONFIG.md`](CONFIG.md) (for developers), [`CONFIG.agents.md`](CONFIG.agents.md) (for AI agents) and `docs.json`
(the docs model both are rendered from) are generated from `contract.cue` by the `docuconf` CLI from
[docuconf-go](https://github.com/docuconf/docuconf-go); never edit them by hand either. Regenerate them after
exporting the contract (CI runs each with `--check` in place of `-o`, against the committed `contract.cue`):

```console
$ docuconf docs contract.cue -o CONFIG.md
$ docuconf docs contract.cue --format agents -o CONFIG.agents.md
$ docuconf docs contract.cue --format model -o docs.json
```

## Deploy

The app ships `contract.cue`, and the platform checks its inputs against it before anything reaches the
cluster: `docuconf vet` reports every bad or missing value, secret given as a literal or policy violation, and
`docuconf render` turns valid inputs into the pod's env, in the encodings the contract names. A Helm-based
platform can use the [docuconf Helm chart](https://github.com/docuconf/docuconf-go/tree/main/helm), which
generates a `values.schema.json` from the contract.
