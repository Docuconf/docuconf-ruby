# frozen_string_literal: true

require "pp"
require "open3"

RSpec.describe "loading a config" do
  def orders_class(&block)
    Class.new(Anyway::Config) do
      include Docuconf::Anyway
      config_name :orders
      env_prefix ""
      attr_config :database_url, port: 8080, request_timeout: "30s"
      required :database_url
      coerce_types request_timeout: :duration
      describe :database_url, "Postgres connection string", type: :url, schemes: %w[postgres], secret: true
      describe :port, "HTTP listen port", min: 1, max: 65_535
      describe :request_timeout, "Request timeout", max: "5m"
      class_eval(&block) if block
    end
  end

  let(:url) { "postgres://u:hunter2@db/orders" }

  describe ".from_env" do
    it "loads from an explicit map without reading or changing ENV" do
      klass = orders_class
      before = ENV.to_h
      with_env("PORT" => "1", "DATABASE_URL" => nil) do
        c = klass.from_env("DATABASE_URL" => url, "PORT" => "9090")
        expect(c.port).to eq 9090
        expect(c.database_url).to eq url
        expect(ENV["PORT"]).to eq "1"
      end
      expect(ENV.to_h).to eq before
    end

    it "raises every problem, and writes no termination log" do
      Dir.mktmpdir do |dir|
        log = File.join(dir, "termination-log")
        with_env("DOCUCONF_TERMINATION_LOG" => log) do
          expect { orders_class.from_env("PORT" => "0") }.to raise_error(Docuconf::Anyway::ValidationError) { |e|
            expect(codes(e)).to contain_exactly(["DATABASE_URL", :missing_required], ["PORT", :out_of_range])
          }
        end
        expect(File.exist?(log)).to be false
      end
    end

    it "reads file inputs under file_root, and starts no watcher thread" do
      Dir.mktmpdir do |root|
        write_file(root, "etc/orders/motd/motd.txt", "hello")
        klass = orders_class { text_file :motd, path: "/etc/orders/motd/motd.txt", description: "Message of the day", reload: :watch }
        Docuconf::Anyway.watch_files = true
        threads = Thread.list.size
        c = klass.from_env({"DATABASE_URL" => url}, file_root: root)
        expect(c.motd).to eq "hello"
        expect(c.docuconf_watcher).to be_nil
        expect(Thread.list.size).to eq threads
      end
    end
  end

  describe ".load!" do
    it "prints every problem and exits 1, without a backtrace" do
      lib = File.expand_path("../lib", __dir__)
      script = <<~RUBY
        require "docuconf/anyway"
        class OrdersConfig < Anyway::Config
          include Docuconf::Anyway
          env_prefix ""
          attr_config :database_url, port: 8080
          required :database_url
          describe :database_url, "Postgres connection string", secret: true
          describe :port, "HTTP listen port", min: 1
        end
        OrdersConfig.load!
        puts "unreachable"
      RUBY
      Dir.mktmpdir do |dir|
        log = File.join(dir, "termination-log")
        out, err, status = Open3.capture3({"PORT" => "0", "DATABASE_URL" => nil, "DOCUCONF_TERMINATION_LOG" => log},
          RbConfig.ruby, "-I", lib, "-e", script)
        expect(status.exitstatus).to eq 1
        expect(out).to eq ""
        expect(err).to eq <<~TXT
          docuconf: 2 configuration problems:
            - DATABASE_URL [missing_required]: required, and not set: set DATABASE_URL in the environment (a secret cannot come from a file)
            - PORT [out_of_range]: 0 is below min 1
        TXT
        expect(File.read(log)).to eq err.chomp
      end
    end
  end

  describe "secrets" do
    it "are filtered from #inspect and pp" do
      c = orders_class.from_env("DATABASE_URL" => url)
      expect(c.inspect).to include(':database_url=>"[FILTERED]"').and include(":port=>8080")
      expect(c.inspect).not_to include("hunter2")
      expect(c.pretty_inspect).to include("[FILTERED]")
      expect(c.pretty_inspect).not_to include("hunter2")
      expect(c.database_url).to eq url
    end

    it "are filtered from errors raised by the app's own on_load checks" do
      klass = orders_class do
        on_load { raise_validation_error("cannot reach #{database_url}") }
      end
      expect { klass.from_env("DATABASE_URL" => url) }
        .to raise_error(Anyway::Config::ValidationError, "cannot reach [FILTERED]")
    end

    it "are filtered as Rails request parameters" do
      orders_class.docuconf_declaration
      value = +"postgres://secret"
      Docuconf::Anyway.filter_secret_parameter("database_url", value)
      expect(value).to eq "[FILTERED]"
      other = +"8080"
      Docuconf::Anyway.filter_secret_parameter("port", other)
      expect(other).to eq "8080"
    end
  end

  describe "typo hints" do
    it "warns about a set variable close to a declared one, without its value" do
      klass = orders_class
      expect { klass.from_env("DATABSE_URL" => "postgres://x:s3cret@h/db", "DATABASE_URL" => url, "PORTT" => "1") }
        .to output(a_string_including("docuconf: DATABSE_URL is set but not declared; did you mean DATABASE_URL?")
          .and(satisfy { |s| !s.include?("s3cret") })).to_stderr
    end

    it "uses the prefix, and ignores unrelated variables" do
      klass = Class.new(Anyway::Config) do
        include Docuconf::Anyway
        config_name :billing
        attr_config port: 8080
        describe :port, "HTTP listen port"
      end
      typos = Docuconf::Anyway::Hints.typos(klass, {"BILLING_PROT" => "1", "HOSTNAME" => "x", "PROT" => "1", "BILLING_PORT" => "1"})
      expect(typos).to eq [%w[BILLING_PROT BILLING_PORT]]
    end
  end

  describe "durations" do
    it "accept Go syntax from the environment, as defaults do" do
      c = orders_class.from_env("DATABASE_URL" => url, "REQUEST_TIMEOUT" => "90s")
      expect(c.request_timeout).to eq 90
      expect { orders_class.from_env("DATABASE_URL" => url, "REQUEST_TIMEOUT" => "ninety") }
        .to raise_error(/"ninety" is not an ISO 8601 duration such as PT30S or a Go duration such as 30s/)
    end

    it "are Float seconds without ActiveSupport, whole or not" do
      script = <<~RUBY
        require "docuconf/anyway"
        abort "ActiveSupport loaded" if defined?(ActiveSupport::Duration)
        class TConfig < Anyway::Config
          include Docuconf::Anyway
          attr_config timeout: "30s"
          coerce_types timeout: :duration
          describe :timeout, "Request timeout"
        end
        p TConfig.from_env("T_TIMEOUT" => "PT30S").timeout, TConfig.from_env("T_TIMEOUT" => "PT0.5S").timeout
      RUBY
      out, status = Open3.capture2e(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", script)
      expect(status).to be_success, out
      expect(out).to eq "30.0\n0.5\n"
    end

    it "format in Go syntax with format_duration" do
      expect(Docuconf::Anyway.format_duration(90.0)).to eq "1m30s"
      expect(Docuconf::Anyway.format_duration(0.5)).to eq "500ms"
    end
  end

  describe "reload: :watch after fork" do
    it "restarts the watcher thread in the child" do
      skip "fork is not available" unless Process.respond_to?(:fork)

      Dir.mktmpdir do |root|
        path = write_file(root, "etc/orders/motd/motd.txt", "hello")
        klass = orders_class { text_file :motd, path: "/etc/orders/motd/motd.txt", description: "Message of the day", reload: :watch }
        Docuconf::Anyway.watch_files = true
        c = nil
        with_env("DOCUCONF_FILE_ROOT" => root, "DATABASE_URL" => url, "DOCUCONF_WATCH_INTERVAL" => "0.05") do
          c = klass.new
          expect(c.docuconf_watcher).to be_alive

          reader, writer = IO.pipe
          pid = fork do
            reader.close
            alive = c.docuconf_watcher.alive?
            File.write(path, "changed")
            deadline = Time.now + 5
            sleep 0.05 until c.motd == "changed" || Time.now > deadline
            writer.puts "alive=#{alive} motd=#{c.motd}"
            writer.close
            exit!(0)
          end
          writer.close
          result = reader.read
          Process.wait(pid)
          expect(result).to eq "alive=true motd=changed\n"
        end
      ensure
        c&.docuconf_watcher&.stop
      end
    end
  end
end
