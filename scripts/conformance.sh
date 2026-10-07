#!/usr/bin/env bash
# Runs only the docuconf-go-facing specs against a given docuconf-go checkout:
# the shared conformance suite (spec/conformance_spec.rb) and the specs that
# `cue vet` exported contracts against its meta-schema (spec/export_spec.rb,
# spec/overlays_spec.rb). Not the full suite.
#
#   DOCUCONF_GO_DIR=/path/to/docuconf-go scripts/conformance.sh
#
# Needs Ruby 3.2+, Bundler and cue on PATH. docuconf-go's downstream workflow
# and this repository's CI both call it.
set -euo pipefail

: "${DOCUCONF_GO_DIR:?set DOCUCONF_GO_DIR to a docuconf-go checkout}"
DOCUCONF_GO_DIR="$(cd "$DOCUCONF_GO_DIR" && pwd)"
export DOCUCONF_GO_DIR
export DOCUCONF_CONFORMANCE="${DOCUCONF_CONFORMANCE:-$DOCUCONF_GO_DIR/conformance/cases.json}"
export DOCUCONF_SPEC_CUE="${DOCUCONF_SPEC_CUE:-$DOCUCONF_GO_DIR/spec/cue}"
export DOCUCONF_REQUIRE_CONFORMANCE=1
export DOCUCONF_REQUIRE_VET=1

cd "$(dirname "$0")/.."
bundle install --quiet
bundle exec rspec spec/conformance_spec.rb spec/export_spec.rb spec/overlays_spec.rb
