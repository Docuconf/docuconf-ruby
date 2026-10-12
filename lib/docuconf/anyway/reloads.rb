# frozen_string_literal: true

module Docuconf
  module Anyway
    # The reload state of one watched input (reload: :watch), for a health
    # check or a metric:
    #
    # - generation: 1 after boot, plus one per accepted reload;
    # - last_reload: the Time of the last accepted reload, or nil;
    # - last_rejected: the last change that failed its checks, as a
    #   RejectedReload, or nil. A later accepted change clears it.
    #
    # It never holds the input's content.
    ReloadStatus = Struct.new(:generation, :last_reload, :last_rejected, keyword_init: true) do
      def to_h
        h = {generation: generation, last_reload: last_reload}
        h[:last_rejected] = last_rejected&.to_h
        h
      end
    end

    # A change to a watched input that failed its checks: when, which input
    # (its contract name) and the violation codes. Never the content.
    RejectedReload = Struct.new(:time, :input, :codes, keyword_init: true)

    # Returned by on_file_change, on_overlay_change and on_change: call
    # #unsubscribe to remove the hook.
    class Subscription
      def initialize(reloads, key, hook)
        @reloads = reloads
        @key = key
        @hook = hook
      end

      # Removes the hook. Returns true the first time, false afterwards.
      def unsubscribe = @reloads.unsubscribe(@key, @hook)
    end

    # Hooks and reload status for the watched inputs of one config (or one
    # contract-first load). Thread-safe: the watcher thread writes, the app
    # reads.
    class Reloads
      def initialize(keys = [])
        @lock = Mutex.new
        @status = keys.to_h { |k| [k, ReloadStatus.new(generation: 1).freeze] }
        @hooks = Hash.new { |h, k| h[k] = [] }
      end

      def keys = @lock.synchronize { @status.keys }

      def watched?(key) = @lock.synchronize { @status.key?(key) }

      # The ReloadStatus of a watched input; ArgumentError for any other.
      def status(key)
        @lock.synchronize do
          @status.fetch(key) { raise ArgumentError, "#{key} is not a watched input (reload: watch)" }
        end
      end

      # Every watched input's ReloadStatus, by key.
      def all = @lock.synchronize { @status.dup }

      def subscribe(key, hook)
        raise ArgumentError, "a reload hook needs a block" unless hook

        @lock.synchronize { @hooks[key] << hook }
        Subscription.new(self, key, hook)
      end

      def unsubscribe(key, hook)
        @lock.synchronize { @hooks[key].delete(hook) ? true : false }
      end

      # Records an accepted reload: the generation goes up by one, the time
      # is now and a previous rejection is cleared.
      def accepted(key, now: Time.now)
        @lock.synchronize do
          s = @status[key] || ReloadStatus.new(generation: 1)
          @status[key] = ReloadStatus.new(generation: s.generation + 1, last_reload: now).freeze
        end
      end

      # Records a rejected change: its time, input name and codes.
      def rejected(key, input:, codes:, now: Time.now)
        @lock.synchronize do
          s = @status[key] || ReloadStatus.new(generation: 1)
          rejection = RejectedReload.new(time: now, input: input, codes: codes.map(&:to_sym).uniq.freeze).freeze
          @status[key] = ReloadStatus.new(generation: s.generation, last_reload: s.last_reload,
            last_rejected: rejection).freeze
        end
      end

      # Calls every hook registered for key with value, in order. A hook
      # that raises is logged by input name and error class only (its
      # message could quote the value), and the others still run.
      def fire(key, value, input:)
        hooks = @lock.synchronize { @hooks[key].dup }
        hooks.each do |hook|
          hook.call(value)
        rescue StandardError => e
          Docuconf::Anyway.warn("on-change hook for #{input} raised #{e.class}", once: false)
        end
        hooks.size
      end
    end
  end
end
