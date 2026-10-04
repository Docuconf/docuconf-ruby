# frozen_string_literal: true

module Docuconf
  module Anyway
    # Honours reload: :watch (SPEC §11.2 item 8). Kubernetes updates a
    # projected volume by swapping the `..data` symlink in the mount
    # directory, so the watcher polls a signature of each watched input's
    # directory (the symlink target plus the size and mtime of its files)
    # and, when it changes, re-reads and re-checks the input. A reload that
    # fails its checks is logged and the previous value kept.
    class Watcher
      DEFAULT_INTERVAL = 2.0

      def self.start(config, interval: nil)
        files = config.class.docuconf_declaration.files.select { |f| f.reload == "watch" }
        return nil if files.empty?

        interval ||= Float(ENV.fetch("DOCUCONF_WATCH_INTERVAL", DEFAULT_INTERVAL))
        watcher = new(config, files, interval: interval)
        config.instance_variable_set(:@docuconf_watcher, watcher)
        watcher.start
      end

      attr_reader :interval

      def initialize(config, files, interval: DEFAULT_INTERVAL, env: ENV)
        @config = config
        @files = files
        @interval = interval
        @env = env
        @signatures = files.to_h { |f| [f.accessor, signature(f)] }
      end

      def start
        return self if interval <= 0

        @thread = Thread.new do
          Thread.current.name = "docuconf-watch"
          loop do
            sleep interval
            poll
          rescue StandardError => e
            Docuconf::Anyway.warn("file watcher error: #{e.class}: #{e.message}")
          end
        end
        @thread.report_on_exception = false
        self
      end

      def stop
        @thread&.kill
        @thread = nil
      end

      # Checks every watched input once; reloads those that changed. Returns
      # the accessors that were reloaded successfully.
      def poll
        reloaded = []
        @files.each do |file|
          sig = signature(file)
          next if sig == @signatures[file.accessor]

          @signatures[file.accessor] = sig
          reloaded << file.accessor if reload(file)
        end
        reloaded
      end

      private

      def reload(file)
        validator = Validator.new(@config, env: @env)
        password = validator.send(:keystore_password, @config.class.docuconf_declaration, file)
        value, failures = Files.load(file, env: @env, password: password)
        unless failures.empty?
          failures.each do |f|
            Docuconf::Anyway.warn("reload of #{file.name} rejected, keeping the previous value: [#{f.code}] #{f.message}")
          end
          return false
        end

        @config.docuconf_files[file.accessor] = value
        Array(@config.docuconf_listeners[file.accessor]).each do |l|
          l.call(value)
        rescue StandardError => e
          Docuconf::Anyway.warn("listener for #{file.name} failed: #{e.class}: #{e.message}")
        end
        true
      end

      def signature(file)
        path = Files.resolve_path(file, @env)
        dir = file.type == "tls" ? path : File.dirname(path)
        data_link = File.join(dir, "..data")
        target = File.symlink?(data_link) ? File.readlink(data_link) : nil
        names = file.type == "tls" ? %w[tls.crt tls.key ca.crt].map { |n| File.join(path, n) } : [path]
        [target] + names.map do |n|
          st = File.stat(n)
          [st.size, st.mtime.to_r, st.ino]
        rescue SystemCallError
          nil
        end
      end
    end
  end
end
