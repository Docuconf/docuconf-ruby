# frozen_string_literal: true

module Docuconf
  module Anyway
    # Stable error codes (SPEC §11.2 item 5).
    ERROR_CODES = %i[
      missing_required invalid_type out_of_range pattern_mismatch not_in_enum
      invalid_scheme too_few_items too_many_items file_missing file_unreadable
      file_too_large file_malformed schema_mismatch certificate_invalid
      certificate_expiring certificate_name_mismatch key_mismatch keystore_unreadable
    ].freeze

    # One problem found at boot. `input` is a variable name (PORT) or a file
    # input name (serving-tls). `message` never contains a secret value.
    Violation = Struct.new(:input, :kind, :code, :message, keyword_init: true) do
      def to_s
        "#{input} [#{code}]: #{message}"
      end
    end

    # The declaration itself is invalid (SPEC §11.2 item 2): raised at
    # definition, export or first load, never because of the environment.
    class DeclarationError < StandardError
      attr_reader :problems

      def initialize(problems)
        @problems = Array(problems)
        super("docuconf: invalid declaration:\n" + @problems.map { |p| "  - #{p}" }.join("\n"))
      end
    end

    # Raised at boot with every violation. It subclasses anyway_config's own
    # ValidationError, so code that rescues that keeps working.
    class ValidationError < ::Anyway::Config::ValidationError
      attr_reader :violations

      def initialize(violations)
        @violations = violations
        super(self.class.format(violations))
      end

      def self.format(violations)
        n = violations.size
        lines = violations.map { |v| "  - #{v}" }
        "docuconf: #{n} configuration problem#{"s" unless n == 1}:\n#{lines.join("\n")}"
      end
    end

    DEFAULT_TERMINATION_LOG = "/dev/termination-log"
    TERMINATION_LOG_LIMIT = 4096

    # Writes the violations where Kubernetes shows them in `kubectl describe
    # pod`. DOCUCONF_TERMINATION_LOG overrides the path (and is written even
    # if it does not exist yet); the default path is only written when it
    # exists, i.e. inside a container. Best effort: never raises.
    def self.write_termination_log(message, env: ENV)
      override = env["DOCUCONF_TERMINATION_LOG"]
      path = override.nil? || override.empty? ? nil : override
      target = path || DEFAULT_TERMINATION_LOG
      return if path.nil? && !File.exist?(target)

      File.binwrite(target, message.b.byteslice(0, TERMINATION_LOG_LIMIT))
    rescue SystemCallError, IOError
      nil
    end
  end
end
