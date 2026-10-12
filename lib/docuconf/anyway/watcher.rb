# frozen_string_literal: true

require "weakref"

module Docuconf
  module Anyway
    # Honours reload: :watch (SPEC §11.2 item 8). Kubernetes updates a
    # projected volume by swapping the `..data` symlink in the mount
    # directory, so the watcher polls a signature of each watched input's
    # directory (the symlink target plus the size and mtime of its files)
    # and, when it changes, re-reads and re-checks the input. A reload that
    # fails its checks is logged and the previous value kept. The thread
    # holds the config weakly and stops once the config is garbage collected.
    #
    # Watched config-file overlays (SPEC §4.7) are polled the same way. When
    # one changes, the whole config is loaded again through anyway_config
    # (YAML, credentials, overlays, environment) into a new instance and
    # validated; if that passes, its values are copied into the running
    # config, otherwise the problems are logged and the old values kept.
    #
    # Each accepted reload bumps the input's ReloadStatus and calls its
    # on-change hooks (see Reloads); a rejected one records the rejection.
    # Keystores are reopened with the password read at boot.
    class Watcher
      DEFAULT_INTERVAL = 2.0

      # Started watchers, held weakly, so a forked child can restart them.
      REGISTRY = ObjectSpace::WeakMap.new
      REGISTRY_LOCK = Mutex.new

      # Threads do not survive fork: start each live watcher's thread again
      # in the child. Called after every Process.fork (see ForkHook).
      def self.restart_all
        list = []
        REGISTRY.each_key { |w| list << w }
        list.each(&:restart)
        list.size
      end

      # Restarts watcher threads in a forked child, so reload: :watch keeps
      # working in Puma cluster workers (preload_app!) and similar.
      module ForkHook
        def _fork
          pid = super
          Docuconf::Anyway::Watcher.restart_all if pid.zero?
          pid
        end
      end
      Process.singleton_class.prepend(ForkHook) if Process.respond_to?(:_fork)

      def self.start(config, interval: nil)
        decl = config.class.docuconf_declaration
        files = decl.files.select { |f| f.reload == "watch" }
        overlays = decl.overlays.select { |o| o.reload == "watch" }
        return nil if files.empty? && overlays.empty?

        interval ||= Float(ENV.fetch("DOCUCONF_WATCH_INTERVAL", DEFAULT_INTERVAL))
        watcher = new(config, files, overlays: overlays, interval: interval)
        config.instance_variable_set(:@docuconf_watcher, watcher)
        watcher.start
      end

      attr_reader :interval

      # passwords: each watched keystore's password by accessor. By default
      # the one the config was loaded with: a reload reuses it and never
      # reads the environment again (it does not change in a running
      # process, so rotating a keystore's password needs a rollout).
      def initialize(config, files, overlays: [], interval: DEFAULT_INTERVAL, env: ENV, passwords: nil)
        @config = config
        @files = files
        @overlays = overlays
        @interval = interval
        @env = env
        @passwords = passwords || boot_passwords(config, files)
        @signatures = files.to_h { |f| [f.accessor, signature(f)] }
        @overlay_signatures = overlays.to_h { |o| [o.name, overlay_signature(o)] }
      end

      def start
        return self if interval <= 0

        # The config references this watcher; the thread must not keep the
        # config alive in return.
        @config_ref = WeakRef.new(@config)
        @config = nil
        REGISTRY[self] = true
        start_thread
      end

      # Starts the polling thread again, after fork. A no-op if the config
      # is gone or the watcher was stopped.
      def restart
        return self unless @config_ref && !@stopped && @config_ref.weakref_alive?
        return self if @thread&.alive?

        start_thread
      rescue WeakRef::RefError
        self
      end

      def alive? = @thread&.alive? ? true : false

      private def start_thread
        @thread = Thread.new do
          Thread.current.name = "docuconf-watch"
          loop do
            sleep interval
            break unless @config_ref.weakref_alive?

            poll
          rescue WeakRef::RefError
            break
          rescue StandardError => e
            Docuconf::Anyway.warn("file watcher error: #{e.class}: #{e.message}")
          end
        end
        @thread.report_on_exception = false
        self
      end

      def stop
        @stopped = true
        @thread&.kill
        @thread = nil
      end

      # Checks every watched input once; reloads those that changed. Returns
      # the accessors that were reloaded successfully, plus
      # `:"overlay:<name>"` for each overlay change that was applied.
      def poll
        reloaded = []
        @files.each do |file|
          sig = signature(file)
          next if sig == @signatures[file.accessor]

          @signatures[file.accessor] = sig
          reloaded << file.accessor if reload(file)
        end
        changed = @overlays.select do |o|
          sig = overlay_signature(o)
          next false if sig == @overlay_signatures[o.name]

          @overlay_signatures[o.name] = sig
        end
        reloaded.concat(changed.map { |o| :"overlay:#{o.name}" }) if !changed.empty? && reload_values(changed)
        reloaded
      end

      private

      def config
        @config || @config_ref.__getobj__
      end

      def reloads = config.docuconf_reloads

      # The key a file input's status and hooks are kept under.
      def file_key(file) = file.accessor

      def store_file(file, value)
        config.docuconf_files[file.accessor] = value
      end

      def boot_passwords(config, files)
        keystores = files.select { |f| f.type == "keystore" }
        return {} if keystores.empty?

        validator = Validator.new(config, env: @env)
        decl = config.class.docuconf_declaration
        keystores.to_h { |f| [f.accessor, validator.send(:keystore_password, decl, f)] }
      end

      def reload(file)
        value, failures = Files.load(file, env: @env, password: @passwords[file.accessor])
        unless failures.empty?
          failures.each do |f|
            Docuconf::Anyway.warn("reload of #{file.name} rejected, keeping the previous value: [#{f.code}] #{f.message}", once: false)
          end
          reloads.rejected(file_key(file), input: file.name, codes: failures.map(&:code))
          return false
        end

        store_file(file, value)
        reloads.accepted(file_key(file))
        reloads.fire(file_key(file), value, input: file.name)
        true
      end

      # Loads the config again into a fresh instance and, when it is valid,
      # copies its values into the running one.
      def reload_values(overlays)
        cfg = config
        fresh = nil
        begin
          saved = [Thread.current[:docuconf_no_watch], Thread.current[:docuconf_reloading]]
          Thread.current[:docuconf_no_watch] = true
          Thread.current[:docuconf_reloading] = true
          fresh = cfg.class.new(cfg.instance_variable_get(:@docuconf_overrides))
        rescue ValidationError => e
          names = overlays.map(&:name).join(", ")
          e.violations.each do |v|
            Docuconf::Anyway.warn("reload of overlay #{names} rejected, keeping the previous values: #{v}", once: false)
          end
          overlays.each { |o| reloads.rejected(:"overlay:#{o.name}", input: o.name, codes: e.violations.map(&:code)) }
          return false
        ensure
          Thread.current[:docuconf_no_watch], Thread.current[:docuconf_reloading] = saved
        end

        cfg.class.config_attributes.each { |a| cfg.public_send(:"#{a}=", fresh.public_send(a)) }
        %i[@docuconf_env @docuconf_loaded].each do |ivar|
          cfg.instance_variable_set(ivar, fresh.instance_variable_get(ivar))
        end
        overlays.each { |o| reloads.accepted(:"overlay:#{o.name}") }
        reloads.fire(:overlays, cfg, input: "overlay #{overlays.map(&:name).join(", ")}")
        true
      end

      def overlay_signature(overlay)
        path_signature(File.dirname(Overlays.resolve_path(overlay, @env)), [Overlays.resolve_path(overlay, @env)])
      end

      def signature(file)
        path = Files.resolve_path(file, @env)
        dir = file.type == "tls" ? path : File.dirname(path)
        names = file.type == "tls" ? %w[tls.crt tls.key ca.crt].map { |n| File.join(path, n) } : [path]
        path_signature(dir, names)
      end

      def path_signature(dir, names)
        data_link = File.join(dir, "..data")
        target = File.symlink?(data_link) ? File.readlink(data_link) : nil
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

module Docuconf
  module Anyway
    # The watcher for a contract-first load (Contract#load): the same
    # polling as Watcher, writing into the Loaded values instead of a
    # config. A changed overlay evaluates the contract again against the
    # environment read at load.
    class ContractWatcher < Watcher
      def initialize(contract, loaded, files, overlays: [], interval: DEFAULT_INTERVAL, env: ENV, passwords: {})
        @contract = contract
        super(loaded, files, overlays: overlays, interval: interval, env: env, passwords: passwords)
      end

      private

      def reloads = config.reloads

      def file_key(file) = file.name

      def store_file(file, value)
        config[file.name] = value
      end

      def reload_values(overlays)
        values, violations = @contract.evaluate(@env)
        # File inputs are reloaded (or kept) on their own.
        violations = violations.reject { |v| v.kind == :file }
        unless violations.empty?
          names = overlays.map(&:name).join(", ")
          violations.each do |v|
            Docuconf::Anyway.warn("reload of overlay #{names} rejected, keeping the previous values: #{v}", once: false)
          end
          overlays.each { |o| reloads.rejected("overlay:#{o.name}", input: o.name, codes: violations.map(&:code)) }
          return false
        end

        loaded = config
        @contract.vars.each { |v| @contract.store(loaded, v.name => values[v.name]) }
        overlays.each { |o| reloads.accepted("overlay:#{o.name}") }
        reloads.fire(:overlays, loaded, input: "overlay #{overlays.map(&:name).join(", ")}")
        true
      end
    end
  end
end
