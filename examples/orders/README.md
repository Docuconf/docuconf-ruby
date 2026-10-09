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
| `WEBHOOK_KEYS` | list of strings, comma-separated | secret, optional; 1–2 keys of 32–256 characters each |

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
{"PORT":8080,"LOG_LEVEL":"info","DATABASE_URL":"***","ALLOWED_ORIGINS":["http://localhost:3000"],"REQUEST_TIMEOUT":"30s","WORKER_COUNT":4,"WEBHOOK_KEYS":"***"}
```

`server.rb` serves [`config.ru`](config.ru) with WEBrick on the configured `PORT`; Puma or `rackup` can serve
`config.ru` as is. `/config` shows the typed values; secrets are always `***`, set or not.

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

[`smoke.sh`](smoke.sh) checks both runs, and the webhook key set below; CI runs it on every push.

## Rotate a key

`WEBHOOK_KEYS` is a key set: `POST /webhooks/payments` accepts a body whose `X-Signature` header is the hex
HMAC-SHA256 of the body under any key in the list ([`webhook.rb`](webhook.rb)). A variable is read once, at
start, so a new key reaches the service only when the pods restart; with two keys valid at once, no webhook is
turned away while that happens:

1. Add the new key as the second item (`old,new` in the Secret), and roll out.
2. Switch the sender to the new key.
3. Remove the old key (`new`), and roll out.

In the platform's values, the key set is a reference to one Secret key that holds `old,new` while rotating:

```yaml
WEBHOOK_KEYS:
  secretKeyRef: {name: orders-webhooks, key: keys}
```

The contract allows 1 or 2 keys of 32 to 256 characters each, so a trailing comma or a truncated key stops the
service at boot instead of locking out the sender, without printing a key:

```console
$ DATABASE_URL=postgres://orders:pw@localhost:5432/orders \
    WEBHOOK_KEYS=old-webhook-key-0123456789abcdef0123, bundle exec ruby server.rb
docuconf: 1 configuration problem:
  - WEBHOOK_KEYS [out_of_range]: item 1 is 0 characters, below item_min_length 32
```

[`test/webhook_test.rb`](test/webhook_test.rb) walks through a rotation (`bundle exec ruby test/webhook_test.rb`),
and [`smoke.sh`](smoke.sh) posts webhooks signed with both keys. [docuconf-go's SPEC section
6.1](https://github.com/docuconf/docuconf-go/blob/main/spec/SPEC.md#61-rotation) covers rotation in general.

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
