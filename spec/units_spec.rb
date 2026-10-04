# frozen_string_literal: true

RSpec.describe Docuconf::Anyway::Duration do
  it "formats canonical Go durations" do
    {"90m" => "1h30m", "1.5h" => "1h30m", "1500ms" => "1s500ms", "0" => "0s", "720h" => "720h"}.each do |i, o|
      expect(described_class.format_go(described_class.parse_go(i))).to eq o
    end
  end

  it "parses ISO 8601 strictly" do
    expect(described_class.parse_iso8601("PT1M30S")).to eq 90_000_000_000
    expect(described_class.parse_iso8601("PT1.5S")).to eq 1_500_000_000
    expect(described_class.parse_iso8601("P1DT1H")).to eq 90_000 * 1_000_000_000
    %w[P PT 30s P1M P1Y -PT1S PT1S\n].each { |bad| expect(described_class.parse_iso8601(bad)).to be_nil }
  end

  it "renders ISO 8601 as the platform does" do
    expect(described_class.format_iso8601(90_000_000_000)).to eq "PT90S"
    expect(described_class.format_iso8601(1_500_000_000)).to eq "PT1.5S"
  end
end

RSpec.describe Docuconf::Anyway::RE2 do
  it "anchors ^ and $ to the whole text unless the m flag is set" do
    expect(described_class.compile("^a$").match?("a\nb")).to be false
    expect(described_class.compile("(?m)^b$").match?("a\nb")).to be true
  end

  it "matches anywhere when unanchored" do
    expect(described_class.compile("b").match?("abc")).to be true
  end

  it "rejects what RE2 does not support" do
    ["a(?=b)", "a(?!b)", "(?<=a)b", "(?<!a)b", "(?>a)", "(a)\\1", "a*+", "\\h", "(?P=n)"].each do |p|
      expect(described_class.problem(p)).not_to be_nil, p
    end
  end

  it "translates RE2-only syntax" do
    expect(described_class.compile("(?P<x>a)").match("a")[:x]).to eq "a"
    expect(described_class.compile("(?s:a.b)").match?("a\nb")).to be true
    expect(described_class.compile("\\Qa.b\\E").match?("axb")).to be false
    expect(described_class.compile("[[a]").match?("[")).to be true
  end
end

RSpec.describe Docuconf::Anyway::Schema do
  S = Docuconf::Anyway::Schema

  it "derives a JSON Schema from a Ruby type spec" do
    expect(S.to_json_schema({name: String, "age?": S.integer(min: 0), tags: [String], ok: :boolean})).to eq(
      "type" => "object",
      "properties" => {
        "name" => {"type" => "string"}, "age" => {"type" => "integer", "minimum" => 0},
        "tags" => {"type" => "array", "items" => {"type" => "string"}}, "ok" => {"type" => "boolean"}
      },
      "required" => %w[name tags ok],
      "additionalProperties" => false
    )
  end

  it "uses #json_schema when an object provides one" do
    spec = Struct.new(:x) { def self.json_schema = {type: "object"} }
    expect(S.to_json_schema(spec)).to eq("type" => "object")
  end

  it "validates data" do
    s = S.to_json_schema({n: S.integer(max: 3), m: S.enum("a", "b"), "o?": S.nullable(String)})
    expect(S.validate(s, {"n" => 2, "m" => "a", "o" => nil})).to eq []
    expect(S.validate(s, {"n" => 4, "m" => "c", "o" => 1})).to contain_exactly(
      "/n: above maximum 3", "/m: must be one of \"a\", \"b\"", "/o: matches none of the allowed shapes (anyOf)"
    )
  end
end
