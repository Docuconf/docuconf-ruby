# frozen_string_literal: true

require "open3"
require_relative "fixtures/export_fixture"

# The shared export check (SPEC §11.2 item 3, §12): the fixture in
# docuconf-go's conformance/export/fixture.yaml, declared in Ruby
# (spec/fixtures/export_fixture.rb), exports to a contract that
# `docuconf conformance export` finds equal, as data, to
# conformance/export/golden.cue.
#
# The docuconf CLI is DOCUCONF_CLI, or is built from DOCUCONF_GO_DIR
# (cmd/docuconf) with Go. Without either the check is skipped, unless
# DOCUCONF_REQUIRE_VET=1.
module ExportFixture
  def self.go_dir
    dir = ENV["DOCUCONF_GO_DIR"]
    dir = File.expand_path("../../docuconf-go", __dir__) if dir.nil? || dir.empty?
    dir
  end

  def self.golden = File.join(go_dir, "conformance/export/golden.cue")

  def self.cli
    @cli ||= begin
      given = ENV["DOCUCONF_CLI"]
      if given && !given.empty?
        given
      elsif File.directory?(File.join(go_dir, "cmd/docuconf")) && system("go version", out: File::NULL, err: File::NULL)
        out = File.join(Dir.mktmpdir("docuconf-cli"), "docuconf")
        _, err, st = Open3.capture3("go", "build", "-o", out, ".", chdir: File.join(go_dir, "cmd/docuconf"))
        raise "building the docuconf CLI failed:\n#{err}" unless st.success?

        out
      end
    end
  end
end

RSpec.describe "shared export fixture" do
  def export
    Docuconf::Anyway.export(name: "docuconf-fixture", app_version: "1.0.0", classes: [Fixtures::ExportFixture],
      profiles: false)
  end

  it "matches conformance/export/golden.cue as data" do
    unless File.file?(ExportFixture.golden) && ExportFixture.cli
      raise "DOCUCONF_REQUIRE_VET=1 but #{ExportFixture.golden} or the docuconf CLI is missing" if ENV["DOCUCONF_REQUIRE_VET"] == "1"

      skip "set DOCUCONF_GO_DIR to a docuconf-go checkout (and DOCUCONF_CLI, or have Go installed)"
    end
    Dir.mktmpdir do |dir|
      exported = File.join(dir, "exported.cue")
      File.write(exported, export)
      out, err, st = Open3.capture3(ExportFixture.cli, "conformance", "export", "--golden", ExportFixture.golden, exported)
      expect(st.success?).to be(true), "#{out}#{err}"
      expect(out).to include("matches")
    end
  end

  it "passes cue vet -c against the meta-schema" do
    require_cue!
    ok, out = cue_vet(export)
    expect(ok).to be(true), out
  end
end
