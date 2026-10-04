# frozen_string_literal: true

require "open3"

# Runs `cue vet -c` on an exported contract against the meta-schema from a
# docuconf-go checkout. Skipped when cue or the meta-schema is missing,
# unless DOCUCONF_REQUIRE_VET=1.
module CueHelper
  def self.spec_dir
    ENV["DOCUCONF_SPEC_CUE"] || File.expand_path("../../../docuconf-go/spec/cue", __dir__)
  end

  def self.cue_bin
    candidates = [ENV["CUE"], File.join(Dir.home, "go/bin/cue")].compact
    found = candidates.find { |c| File.executable?(c) }
    return found if found

    ENV["PATH"].to_s.split(File::PATH_SEPARATOR).map { |d| File.join(d, "cue") }.find { |c| File.executable?(c) }
  end

  def require_cue!
    missing = []
    missing << "cue" unless CueHelper.cue_bin
    missing << "meta-schema at #{CueHelper.spec_dir}" unless File.directory?(File.join(CueHelper.spec_dir, "contract"))
    return if missing.empty?

    raise "DOCUCONF_REQUIRE_VET=1 but missing: #{missing.join(", ")}" if ENV["DOCUCONF_REQUIRE_VET"] == "1"

    skip "missing #{missing.join(", ")}"
  end

  # Returns [ok, output].
  def cue_vet(text)
    Dir.mktmpdir("docuconf-cue") do |dir|
      FileUtils.cp_r(File.join(CueHelper.spec_dir, "cue.mod"), dir)
      FileUtils.cp_r(File.join(CueHelper.spec_dir, "contract"), dir)
      FileUtils.mkdir_p(File.join(dir, "svc"))
      File.write(File.join(dir, "svc", "contract.cue"), text)
      out, status = Open3.capture2e(CueHelper.cue_bin, "vet", "-c", "./svc", chdir: dir)
      [status.success?, out]
    end
  end

  # The contract as JSON data, via `cue export`.
  def cue_export(text)
    Dir.mktmpdir("docuconf-cue") do |dir|
      FileUtils.cp_r(File.join(CueHelper.spec_dir, "cue.mod"), dir)
      FileUtils.cp_r(File.join(CueHelper.spec_dir, "contract"), dir)
      FileUtils.mkdir_p(File.join(dir, "svc"))
      File.write(File.join(dir, "svc", "contract.cue"), text)
      out, status = Open3.capture2e(CueHelper.cue_bin, "export", "./svc", "--out", "json", chdir: dir)
      raise out unless status.success?

      JSON.parse(out)
    end
  end
end

RSpec.configure { |c| c.include CueHelper }
