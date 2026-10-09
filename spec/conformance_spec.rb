# frozen_string_literal: true

require "json"
require "base64"
require "fileutils"

# The shared conformance suite (SPEC §12): every case in docuconf-go's
# conformance/cases.json, run through contract-first mode. The file comes
# from DOCUCONF_CONFORMANCE, falling back to a docuconf-go checkout next to
# this repository. A missing file skips the suite, unless
# DOCUCONF_REQUIRE_CONFORMANCE=1.
module Conformance
  # The capability tags (conformance/README.md) this SDK supports. It is an
  # allow-list: a case needing a tag that is not here, including one this
  # runner has never heard of, is skipped, never run (SPEC §12). Ruby holds
  # every 64-bit integer and validates json values against their JSON
  # Schema, and contract-first mode has key sets, deprecated inputs, strict
  # parsing, file inputs, profiles and overlays, so no case is skipped.
  SUPPORTED_TAGS = %w[int64 json-schema key-set deprecated strict-parsing files profiles overlays].freeze

  def self.path
    env = ENV["DOCUCONF_CONFORMANCE"]
    return env if env && !env.empty?

    File.expand_path("../../docuconf-go/conformance/cases.json", __dir__)
  end

  def self.required? = ENV["DOCUCONF_REQUIRE_CONFORMANCE"] == "1"

  def self.cases
    return nil unless File.file?(path)

    suite = JSON.parse(File.read(path, encoding: "UTF-8"))
    raise "#{path}: unsupported suite version #{suite["version"].inspect}" unless suite["version"] == 1

    suite.fetch("cases")
  end

  def self.skip?(c) = !(Array(c["requires"]) - SUPPORTED_TAGS).empty?

  # Writes each of the case's files under root, at its absolute path.
  def self.write_files(root, files)
    (files || {}).each do |path, f|
      data = f.key?("base64") ? Base64.strict_decode64(f["base64"]) : f.fetch("text")
      dest = File.join(root, path)
      FileUtils.mkdir_p(File.dirname(dest))
      File.binwrite(dest, data)
    end
  end

  # A typed value as JSON data, for comparison with `expect`.
  def self.to_json_value(var, value)
    return nil if value.nil?

    case var.type
    when "duration" then Docuconf::Anyway::Duration.format_go(Docuconf::Anyway::Duration.to_ns(value), signed: true)
    when "keySet" then value.keys
    else value
    end
  end

  # A file input's value as JSON data: a config file's data, a text file's
  # text, and true for any other file that is present.
  def self.file_json_value(file, value)
    return nil if value.nil?

    %w[config text].include?(file.type) ? value : true
  end

  # Compares JSON data, numbers by value.
  def self.same_data?(a, b)
    case b
    when Hash then a.is_a?(Hash) && a.keys.sort == b.keys.sort && b.all? { |k, v| same_data?(a[k], v) }
    when Array then a.is_a?(Array) && a.size == b.size && a.zip(b).all? { |x, y| same_data?(x, y) }
    when Numeric then a.is_a?(Numeric) && a.to_r == b.to_r
    else a == b
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
    skipped = cases.select { |c| Conformance.skip?(c) }

    # The SDK supports every tag in the suite: a skipped case is a failure,
    # so CI cannot go green while a case is left out. A tag this runner does
    # not know still skips its cases (they are not run), and this fails
    # until the tag is added to SUPPORTED_TAGS.
    it "runs every case (#{cases.size} cases, #{skipped.size} skipped)" do
      tags = skipped.flat_map { |c| Array(c["requires"]) - Conformance::SUPPORTED_TAGS }.tally
      $stdout.puts "\nconformance: #{cases.size} cases in #{Conformance.path}, #{skipped.size} skipped"
      expect(skipped).to be_empty,
        "skipped #{skipped.size} of #{cases.size} case(s) needing unsupported tags #{tags}: " \
        "#{skipped.map { |c| c["id"] }.join(", ")}"
    end

    (cases - skipped).each do |c|
      it c["id"] do
        Dir.mktmpdir("docuconf-conformance") do |tmp|
          # Files go under a fresh, empty DOCUCONF_FILE_ROOT, set for every
          # case, so that no case reads the machine's own files.
          root = File.join(tmp, "root")
          FileUtils.mkdir_p(root)
          Conformance.write_files(root, c["files"])
          log = File.join(tmp, "termination-log")
          contract = Docuconf::Anyway::Contract.parse(c["contract"])
          env = c["env"].merge("DOCUCONF_FILE_ROOT" => root)
          id = "#{c["id"]} (#{c["source"]})"

          with_env("DOCUCONF_TERMINATION_LOG" => log) do
            if c.key?("expect")
              values = contract.load(env)
              c["expect"].each do |name, expected|
                if (var = contract.var(name))
                  actual = Conformance.to_json_value(var, values[name])
                  ok = Conformance.same?(var, actual, expected)
                elsif (file = contract.file(name))
                  actual = Conformance.file_json_value(file, values[name])
                  ok = expected.nil? ? actual.nil? : Conformance.same_data?(actual, expected)
                else
                  raise "#{id}: #{name} is not in the contract"
                end
                expect(ok).to be(true), "#{id}: #{name} is #{actual.inspect}, expected #{expected.inspect}"
              end
            else
              error = nil
              begin
                contract.load(env)
              rescue Docuconf::Anyway::ValidationError => e
                error = e
              end
              expect(error).not_to be_nil, "#{id}: loading succeeded, expected #{c["errors"].inspect}"
              got = error.violations.map { |v| [v.input, v.code.to_s] }
              want = c["errors"].map { |x| [x["var"], x["code"]] }
              expect(got).to match_array(want), "#{id}: got #{got.inspect}, expected #{want.inspect}"

              written = File.exist?(log) ? File.read(log) : ""
              contract.vars.select(&:secret).each do |var|
                c["env"].select { |k, v| (k == var.name || k.start_with?("#{var.name}__")) && !v.empty? }.each_value do |raw|
                  expect(error.message).not_to include(raw), "#{id}: the error message shows #{var.name}"
                  expect(written).not_to include(raw), "#{id}: the termination log shows #{var.name}"
                end
              end
            end
          end
        end
      end
    end
  end
end
