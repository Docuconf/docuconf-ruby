#!/usr/bin/env bash
# Smoke test: runs the shop as a real process in each role with valid env,
# and with JSON logs but no LOG_SCHEMA_URL, checking stdout, stderr and the
# exit code. Needs ruby and bundler (after `bundle install` here).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cd "$here"

secret='postgres://shop@db:5432/shop'

# Runs the shop with the base env plus the arguments (NAME=value) and a
# fresh, empty file root; wants exit status $1 and stdout $2 (on a failure,
# stderr containing $3).
check() {
  local want_status=$1 want_out=$2 want_err=$3 status=0
  shift 3
  mkdir "$tmp/root" "$tmp/run"
  # Only the variables given here: none of the contract's from the caller.
  env $(ruby -rjson -e 'puts JSON.parse(File.read("contract.json"))["vars"].keys.map { |k| "-u #{k}" }') \
    DATABASE_URL="$secret" DOCUCONF_FILE_ROOT="$tmp/root" DOCUCONF_TERMINATION_LOG="$tmp/run/termination-log" "$@" \
    bundle exec ruby shop.rb >"$tmp/run/out" 2>"$tmp/run/err" || status=$?
  if [ "$status" != "$want_status" ] || [ "$(cat "$tmp/run/out")" != "$want_out" ]; then
    echo "$*: want exit $want_status and stdout '$want_out', got $status:" >&2
    cat "$tmp/run/out" "$tmp/run/err" >&2; exit 1
  fi
  if [ -n "$want_err" ] && ! grep -qF -- "$want_err" "$tmp/run/err"; then
    echo "$*: stderr lacks '$want_err':" >&2; cat "$tmp/run/err" >&2; exit 1
  fi
  if grep -qF "$secret" "$tmp/run/out" "$tmp/run/err"; then
    echo "$*: printed DATABASE_URL" >&2; exit 1
  fi
  echo "ok: $* -> exit $status${want_out:+, $want_out}"
  rm -rf "$tmp/root" "$tmp/run"
}

# 1. web
check 0 'shop web: port 8080, origins https://shop.example' '' \
  DOCUCONF_ROLE=web ALLOWED_ORIGINS=https://shop.example
# 2. worker: no ALLOWED_ORIGINS needed
check 0 'shop worker: queues default,mail, webhooks off' '' \
  DOCUCONF_ROLE=worker QUEUES=default,mail
# 6. JSON logs need LOG_SCHEMA_URL
check 1 '' 'LOG_SCHEMA_URL [missing_required]: is required when LOG_FORMAT is "json"' \
  DOCUCONF_ROLE=worker QUEUES=default LOG_FORMAT=json
echo "smoke: ok"
