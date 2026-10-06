# frozen_string_literal: true

module Docuconf
  module Anyway
    # Durations. Contracts always use canonical Go syntax ("1m30s"); the wire
    # encoding this SDK declares is ISO 8601 ("PT90S"), which
    # ActiveSupport::Duration.parse reads natively. Internally a duration is
    # an Integer number of nanoseconds.
    module Duration
      NS = {
        "ns" => 1, "us" => 1_000, "µs" => 1_000, "μs" => 1_000, "ms" => 1_000_000,
        "s" => 1_000_000_000, "m" => 60_000_000_000, "h" => 3_600_000_000_000
      }.freeze
      GO_PART = /\A([0-9]*(?:\.[0-9]*)?)(ns|us|µs|μs|ms|s|m|h)/
      # The meta-schema's #Duration: integer components, no sign.
      CONTRACT_FORM = /\A(?:[0-9]+(?:ns|us|ms|s|m|h))+\z/
      ISO8601 = /\AP(?:([0-9]+)W)?(?:([0-9]+)D)?(?:T(?:([0-9]+)H)?(?:([0-9]+)M)?(?:([0-9]+)(?:[.,]([0-9]{1,9}))?S)?)?\z/
      UNITS = [["h", 3_600_000_000_000], ["m", 60_000_000_000], ["s", 1_000_000_000],
        ["ms", 1_000_000], ["us", 1_000], ["ns", 1]].freeze

      module_function

      # Parses Go duration syntax (time.ParseDuration). Returns nanoseconds or nil.
      def parse_go(input)
        return nil unless input.is_a?(String)

        s = input.dup
        sign = 1
        if s.start_with?("-", "+")
          sign = -1 if s.start_with?("-")
          s = s[1..]
        end
        return 0 if s == "0"
        return nil if s.empty?

        total = Rational(0)
        until s.empty?
          m = GO_PART.match(s)
          return nil unless m
          return nil unless m[1].match?(/[0-9]/)

          total += Rational(m[1].start_with?(".") ? "0#{m[1]}" : m[1].chomp(".")) * NS.fetch(m[2])
          s = s[m[0].length..]
        end
        (sign * total).round
      end

      # Parses ISO 8601 durations of weeks, days, hours, minutes and seconds
      # (PT90S, P1DT2H, PT1.5S). Years and months have no fixed length and are
      # rejected. Returns nanoseconds or nil.
      def parse_iso8601(input)
        return nil unless input.is_a?(String)

        m = ISO8601.match(input)
        return nil unless m
        return nil if m.captures.compact.empty?
        return nil if input.end_with?("T")

        w, d, h, mi, s, frac = m.captures
        secs = (w.to_i * 7 * 86_400) + (d.to_i * 86_400) + (h.to_i * 3600) + (mi.to_i * 60) + s.to_i
        ns = secs * 1_000_000_000
        ns += frac.ljust(9, "0").to_i if frac
        ns
      end

      SECONDS = /\A([0-9]+)(?:\.([0-9]{1,9}))?\z/
      # .NET TimeSpan's invariant "c" format: [d.]hh:mm:ss[.fffffff].
      TIMESPAN = /\A(?:([0-9]+)\.)?([0-9]{1,2}):([0-9]{2}):([0-9]{2})(?:\.([0-9]{1,7}))?\z/

      # Parses a duration in a contract wire encoding (SPEC §5): go,
      # iso8601, seconds or timespan. Returns nanoseconds or nil; a
      # duration is never negative.
      def parse_wire(input, encoding)
        ns =
          case encoding
          when "go" then parse_go(input)
          when "iso8601" then parse_iso8601(input)
          when "seconds" then parse_seconds(input)
          when "timespan" then parse_timespan(input)
          end
        ns&.negative? ? nil : ns
      end

      # A decimal number of seconds (90, 0.25). Returns nanoseconds or nil.
      def parse_seconds(input)
        m = SECONDS.match(input.to_s)
        return nil unless m

        (m[1].to_i * 1_000_000_000) + (m[2] ? m[2].ljust(9, "0").to_i : 0)
      end

      # A .NET TimeSpan ([d.]hh:mm:ss[.fff]). Returns nanoseconds or nil.
      def parse_timespan(input)
        m = TIMESPAN.match(input.to_s)
        return nil unless m

        d, h, mi, s, frac = m.captures
        return nil if h.to_i > 23 || mi.to_i > 59 || s.to_i > 59

        secs = (d.to_i * 86_400) + (h.to_i * 3600) + (mi.to_i * 60) + s.to_i
        (secs * 1_000_000_000) + (frac ? frac.ljust(9, "0").to_i : 0)
      end

      # A wire encoding's name for messages.
      def describe_encoding(encoding)
        {
          "go" => "a Go duration such as 1m30s", "iso8601" => "an ISO 8601 duration such as PT30S",
          "seconds" => "a number of seconds such as 90", "timespan" => "a TimeSpan such as 00:01:30"
        }.fetch(encoding, "a duration")
      end

      # Canonical Go form, as the contract requires ("1h30m", "1s500ms", "0s").
      def format_go(ns)
        raise ArgumentError, "cannot express a negative duration in a contract" if ns.negative?
        return "0s" if ns.zero?

        out = +""
        UNITS.each do |unit, size|
          q, ns = ns.divmod(size)
          out << "#{q}#{unit}" if q.positive?
        end
        out
      end

      # Canonical ISO 8601 form, as #Render emits it (PT90S, PT1.5S).
      def format_iso8601(ns)
        ms = ns / 1_000_000
        secs, frac = ms.divmod(1000)
        frac.zero? ? "PT#{secs}S" : "PT#{secs}.#{format("%03d", frac).sub(/0+\z/, "")}S"
      end

      # Converts a declared or loaded value (Go or ISO 8601 string, number of
      # seconds, ActiveSupport::Duration) to nanoseconds. Returns nil if it is
      # not a duration.
      def to_ns(value)
        case value
        when nil then nil
        when Integer then value * 1_000_000_000
        when Float then value.finite? ? (value * 1_000_000_000).round : nil
        when Rational then (value * 1_000_000_000).round
        when String then parse_iso8601(value) || parse_go(value)
        else
          if defined?(::ActiveSupport::Duration) && value.is_a?(::ActiveSupport::Duration)
            (value.to_r * 1_000_000_000).round
          end
        end
      end

      # The value handed to the application: an ActiveSupport::Duration when
      # ActiveSupport is loaded, otherwise a number of seconds (an Integer
      # when whole, else a Rational).
      def build(ns)
        secs = Rational(ns, 1_000_000_000)
        secs = secs.to_i if secs.denominator == 1
        if defined?(::ActiveSupport::Duration)
          ::ActiveSupport::Duration.build(secs)
        else
          secs
        end
      end

      # The anyway_config caster registered as :duration.
      def cast(value)
        return value if defined?(::ActiveSupport::Duration) && value.is_a?(::ActiveSupport::Duration)
        return value if value.nil?

        if value.is_a?(String) && defined?(::ActiveSupport::Duration) && parse_iso8601(value)
          return ::ActiveSupport::Duration.parse(value)
        end

        ns = to_ns(value)
        raise ArgumentError, "not a duration: #{value.inspect}" if ns.nil?

        build(ns)
      end
    end
  end
end
