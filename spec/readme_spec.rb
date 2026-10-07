# frozen_string_literal: true

require "open3"

# Keeps README.md and docs/reference.md honest: every Ruby snippet compiles,
# and the snippets marked <!-- readme: NAME --> are run as a user would run
# them, in a scratch project.
RSpec.describe "README snippets" do
  def self.root = File.expand_path("..", __dir__)
  def root = self.class.root

  def blocks(file)
    text = File.read(File.join(self.class.root, file), encoding: "UTF-8")
    text.scan(/(?:<!-- readme: ([\w-]+) -->\n)?```(\w+)\n(.*?)^```\n/m).map do |name, lang, code|
      {name: name, lang: lang, code: code}
    end
  end

  def snippet(name)
    blocks("README.md").find { |b| b[:name] == name }&.fetch(:code) or raise "no README snippet #{name}"
  end

  def ruby(dir, env, *args)
    Open3.capture3(env, RbConfig.ruby, "-I", File.join(root, "lib"), "-rdocuconf/anyway", *args, chdir: dir)
  end

  %w[README.md docs/reference.md].each do |file|
    it "has only Ruby snippets that compile (#{file})" do
      ruby_blocks = blocks(file).select { |b| b[:lang] == "ruby" }
      expect(ruby_blocks).not_to be_empty
      ruby_blocks.each do |b|
        expect { RubyVM::InstructionSequence.compile(b[:code]) }.not_to raise_error, b[:code]
      end
    end
  end

  it "installs from git" do
    expect(snippet("gemfile")).to include('gem "docuconf-anyway", github: "Docuconf/docuconf-ruby"')
    gemspec = Gem::Specification.load(File.join(root, "docuconf-anyway.gemspec"))
    expect(gemspec.name).to eq "docuconf-anyway"
  end

  context "in a scratch project" do
    around do |example|
      Dir.mktmpdir do |dir|
        @dir = dir
        FileUtils.mkdir_p(File.join(dir, "config/configs"))
        File.write(File.join(dir, "config/configs/orders_config.rb"), snippet("config"))
        File.write(File.join(dir, "app.rb"), %(require_relative "config/configs/orders_config"\n#{snippet("boot")}))
        example.run
      end
    end

    let(:clean_env) { {"PORT" => nil, "DATABASE_URL" => nil, "DATABSE_URL" => nil, "DOCUCONF_TERMINATION_LOG" => File::NULL} }

    it "runs the declaration and load!" do
      out, err, status = ruby(@dir, clean_env.merge("DATABASE_URL" => "postgres://localhost/orders"), "app.rb")
      expect(status).to be_success, err
      expect(out).to eq "listening on 8080, timeout 30s\n"
    end

    it "prints the error shown" do
      console = snippet("error").lines
      command = console.shift.delete_prefix("$ ").strip
      vars = command.scan(/(\w+)=(\S+)/).to_h
      expect(command).to end_with("ruby app.rb")
      _out, err, status = ruby(@dir, clean_env.merge(vars), "app.rb")
      expect(status.exitstatus).to eq 1
      expect(err).to eq console.join
    end

    it "passes the RSpec example" do
      FileUtils.mkdir_p(File.join(@dir, "spec/configs"))
      File.write(File.join(@dir, "spec/configs/orders_config_spec.rb"),
        %(require_relative "../../config/configs/orders_config"\n#{snippet("spec")}))
      rspec = Gem.bin_path("rspec-core", "rspec")
      out, err, status = ruby(@dir, clean_env, rspec, "--no-color", "spec/configs/orders_config_spec.rb")
      expect(status).to be_success, out + err
      expect(out).to include("2 examples, 0 failures")
    end

    it "exports with the command shown" do
      command = snippet("export").strip
      args = command.delete_prefix("bundle exec docuconf ").split
      _out, err, status = ruby(@dir, clean_env, File.join(root, "exe/docuconf"), *args)
      expect(status).to be_success, err
      cue = File.read(File.join(@dir, "contract.cue"))
      expect(cue).to include("name: \"orders-api\"").and include("PORT: {").and include("type:        \"duration\"")

      check = snippet("check").strip.delete_prefix("bundle exec docuconf ").split
      _out, err, status = ruby(@dir, clean_env, File.join(root, "exe/docuconf"), *check)
      expect(status).to be_success, err
      expect(err).to include("contract.cue is up to date")
      File.write(File.join(@dir, "contract.cue"), cue.sub("8080", "8081"))
      _out, _err, status = ruby(@dir, clean_env, File.join(root, "exe/docuconf"), *check)
      expect(status.exitstatus).to eq 1
    end

    it "documents only rake options docuconf:export reads" do
      task = File.read(File.join(root, "lib/docuconf/anyway/tasks.rake"))
      snippet("rails-export").scan(/\b([A-Z_]+)=/).flatten.each do |var|
        expect(task).to include(%(ENV["#{var}"]))
      end
    end
  end
end
