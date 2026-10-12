#!/usr/bin/env bash
# Smoke test: starts the orders service with valid env and checks its
# endpoints, then starts it with bad env and checks it refuses to boot, and
# posts webhooks signed with each key of a key set that is mid-rotation.
# Needs ruby, bundler (after `bundle install` here) and curl.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
pid=""
trap '[ -n "$pid" ] && kill "$pid" 2>/dev/null; rm -rf "$tmp"' EXIT
cd "$here"

secret='postgres://orders:s3cr3t-pw@localhost:5432/orders'
port=${SMOKE_PORT:-18087}
# Two webhook keys: the old one and, mid-rotation, the new one.
old_key='old-webhook-key-0123456789abcdef0123'
new_key='new-webhook-key-0123456789abcdef0123'

# 1. Valid env: the service serves /healthz and /config, without the secret.
PORT=$port DATABASE_URL="$secret" WEBHOOK_KEYS="$old_key,$new_key" bundle exec ruby server.rb >"$tmp/out.txt" 2>&1 &
pid=$!
# Wait for WEBrick to report it listens, so that a stray process on the
# same port cannot answer instead.
for _ in $(seq 150); do
  kill -0 "$pid" 2>/dev/null || { echo "the service exited:" >&2; cat "$tmp/out.txt" >&2; exit 1; }
  grep -q "port=$port" "$tmp/out.txt" && break
  sleep 0.1
done
curl -fsS "http://127.0.0.1:$port/healthz" >"$tmp/healthz" || true
[ "$(cat "$tmp/healthz" 2>/dev/null)" = ok ] || { echo "GET /healthz did not return ok" >&2; cat "$tmp/out.txt" >&2; exit 1; }
curl -fsS "http://127.0.0.1:$port/config" >"$tmp/config.json"
if grep -q -e 's3cr3t-pw' -e 'webhook-key' "$tmp/config.json"; then
  echo "GET /config leaked a secret" >&2; exit 1
fi
grep -qF '"DATABASE_URL":"***"' "$tmp/config.json" || { echo "GET /config did not redact DATABASE_URL:" >&2; cat "$tmp/config.json" >&2; exit 1; }
grep -qF '"WEBHOOK_KEYS":"***"' "$tmp/config.json" || { echo "GET /config did not redact WEBHOOK_KEYS:" >&2; cat "$tmp/config.json" >&2; exit 1; }
echo "valid env: /healthz ok, /config $(cat "$tmp/config.json")"

# Mid-rotation, a webhook signed with either key is accepted, and one signed
# with any other key, or not at all, is not.
body='{"order":"42","status":"paid"}'
post() { curl -s -o /dev/null -w '%{http_code}' -X POST "$@" -d "$body" "http://127.0.0.1:$port/webhooks/payments"; }
code=$(post)
[ "$code" = 401 ] || { echo "an unsigned webhook got $code, want 401" >&2; exit 1; }
for key in "$old_key" "$new_key" "other-webhook-key-0123456789abcdef"; do
  sig=$(ruby -ropenssl -e 'print OpenSSL::HMAC.hexdigest("SHA256", ARGV[0], ARGV[1])' "$key" "$body")
  want=204; [ "${key#other}" != "$key" ] && want=401
  code=$(post -H "X-Signature: $sig")
  [ "$code" = "$want" ] || { echo "webhook signed with the ${key%%-*} key: got $code, want $want" >&2; exit 1; }
done
echo "webhooks: old and new key accepted, any other rejected"
kill "$pid"; wait "$pid" 2>/dev/null || true; pid=""
if grep -q webhook-key "$tmp/out.txt"; then echo "the log contains a webhook key" >&2; exit 1; fi

# 2. PORT=0 and no DATABASE_URL: the service exits non-zero and names both.
if env -u DATABASE_URL PORT=0 bundle exec ruby server.rb >"$tmp/bad.txt" 2>&1; then
  echo "service started with PORT=0 and no DATABASE_URL" >&2; exit 1
fi
for code in missing_required out_of_range; do
  grep -q "$code" "$tmp/bad.txt" || { echo "startup output lacks $code:" >&2; cat "$tmp/bad.txt" >&2; exit 1; }
done
echo "bad env: exited non-zero with:"
sed 's/^/  /' "$tmp/bad.txt"

# 3. A key set with an empty second key (a trailing comma): an empty key is
# always out of range, so it fails at boot, without printing the key.
status=0
DATABASE_URL="$secret" WEBHOOK_KEYS="$old_key," bundle exec ruby server.rb >"$tmp/bad.txt" 2>&1 || status=$?
cat >"$tmp/want.txt" <<'WANT'
docuconf: 1 configuration problem:
  - WEBHOOK_KEYS [out_of_range]: key 2 is empty
WANT
if [ "$status" != 1 ] || ! diff -u "$tmp/want.txt" "$tmp/bad.txt" || grep -q webhook-key "$tmp/bad.txt"; then
  echo "want exit 1 for an empty webhook key, got $status:" >&2; cat "$tmp/bad.txt" >&2; exit 1
fi
echo "empty webhook key: exited 1"
echo "smoke: ok"
