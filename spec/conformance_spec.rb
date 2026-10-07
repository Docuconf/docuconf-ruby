# frozen_string_literal: true

require "json"

# The shared conformance suite (SPEC §12): every case in docuconf-go's
# conformance/cases.json, run through contract-first mode. The file comes
# from DOCUCONF_CONFORMANCE, falling back to a docuconf-go checkout next to
# this repository. A missing file skips the suite, unless
# DOCUCONF_REQUIRE_CONFORMANCE=1.
module Conformance
  # Capability tags (conformance/README.md) this SDK lacks. Ruby holds every
  # 64-bit integer, and validates json values against their JSON Schema, so
  # none are skipped.
  UNSUPPORTED_TAGS = [].freeze

  def self.path
    env = ENV["DOCUCONF_CONFORMANCE"]
    return env if env && !env.empty?

    File.expand_path("../../docuconf-go/conformance/cases.json", __dir__)
  end

  def self.required? = ENV["DOCUCONF_REQUIRE_CONFORMANCE"] == "1"

  def self.cases
    return nil unless File.file?(path)

    JSON.parse(File.read(path, encoding: "UTF-8")).fetch("cases")
  end

  # A typed value as JSON data, for comparison with `expect`.
  def self.to_json_value(var, value)
    return nil if value.nil?

    case var.type
    when "duration" then Docuconf::Anyway::Duration.format_go(Docuconf::Anyway::Duration.to_ns(value))
    else value
    end
  end

  def self.same?(var, actual, expected)
    return actual.nil? if expected.nil?
    return actual.is_a?(Numeric) && expected.is_a?(Numeric) && actual.to_r == expected.to_r if var.type == "float"
    return actual.is_a?(Integer) && actual == expected if var.type == "int"

    actual == expected
  end
end

RSpec.describe "conformance suite" do
  cases = Conformance.cases

  if cases.nil?
    it "runs the cases in #{Conformance.path}" do
      raise "DOCUCONF_REQUIRE_CONFORMANCE=1 but #{Conformance.path} does not exist" if Conformance.required?

      skip "#{Conformance.path} not found; set DOCUCONF_CONFORMANCE"
    end
  else
    skipped = cases.select { |c| (Array(c["requires"]) & Conformance::UNSUPPORTED_TAGS).any? }
    unless skipped.empty?
      it "skips #{skipped.size} case(s) needing #{(skipped.flat_map { |c| c["requires"] } & Conformance::UNSUPPORTED_TAGS).uniq.join(", ")}" do
        skip skipped.map { |c| c["id"] }.join(", ")
      end
    end

    (cases - skipped).each do |c|
      it c["id"] do
        Dir.mktmpdir("docuconf-conformance") do |dir|
          log = File.join(dir, "termination-log")
          contract = Docuconf::Anyway::Contract.parse(c["contract"])
          env = c["env"]

          with_env("DOCUCONF_TERMINATION_LOG" => log) do
            if c.key?("expect")
              values = contract.load(env)
              c["expect"].each do |name, expected|
                var = contract.var(name)
                expect(var).not_to be_nil, "#{c["id"]}: #{name} is not in the contract"
                actual = Conformance.to_json_value(var, values[name])
                expect(Conformance.same?(var, actual, expected)).to be(true),
                  "#{c["id"]}: #{name} is #{actual.inspect}, expected #{expected.inspect}"
              end
            else
              error = nil
              begin
                contract.load(env)
              rescue Docuconf::Anyway::ValidationError => e
                error = e
              end
              expect(error).not_to be_nil, "#{c["id"]}: loading succeeded, expected #{c["errors"].inspect}"
              got = error.violations.map { |v| [v.input, v.code.to_s] }
              want = c["errors"].map { |x| [x["var"], x["code"]] }
              expect(got).to match_array(want), "#{c["id"]}: got #{got.inspect}, expected #{want.inspect}"

              written = File.exist?(log) ? File.read(log) : ""
              contract.vars.select(&:secret).each do |var|
                env.select { |k, v| (k == var.name || k.start_with?("#{var.name}__")) && !v.empty? }.each_value do |raw|
                  expect(error.message).not_to include(raw), "#{c["id"]}: the error message shows #{var.name}"
                  expect(written).not_to include(raw), "#{c["id"]}: the termination log shows #{var.name}"
                end
              end
            end
          end
        end
      end
    end
  end
end
