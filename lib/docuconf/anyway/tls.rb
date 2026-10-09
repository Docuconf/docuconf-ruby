# frozen_string_literal: true

require "openssl"
require "time"

module Docuconf
  module Anyway
    # A checked TLS key pair. #inspect and #to_s never show the key.
    class TLSMaterial
      attr_reader :cert_pem, :key_pem, :ca_pem, :certificate, :chain, :key, :ca_certificates

      def initialize(cert_pem:, key_pem:, ca_pem:, chain:, key:, ca_certificates:)
        @cert_pem = cert_pem
        @key_pem = key_pem
        @ca_pem = ca_pem
        @chain = chain.freeze
        @certificate = chain.first
        @key = key
        @ca_certificates = (ca_certificates || []).freeze
        freeze
      end

      # An SSLContext serving this certificate (with its chain), trusting
      # ca.crt for client certificates when present.
      def ssl_context
        ctx = OpenSSL::SSL::SSLContext.new
        ctx.add_certificate(certificate, key, chain[1..] || [])
        unless ca_certificates.empty?
          store = OpenSSL::X509::Store.new
          ca_certificates.each { |c| store.add_cert(c) }
          ctx.cert_store = store
        end
        ctx
      end

      def inspect
        "#<#{self.class.name} subject=#{certificate.subject} not_after=#{certificate.not_after.utc.iso8601} key=[redacted]>"
      end
      alias_method :to_s, :inspect
    end

    # A checked CA bundle.
    class CABundle
      attr_reader :pem, :certificates

      def initialize(pem, certificates)
        @pem = pem
        @certificates = certificates.freeze
        freeze
      end

      # An X509::Store trusting exactly these certificates.
      def store
        OpenSSL::X509::Store.new.tap { |s| certificates.each { |c| s.add_cert(c) } }
      end

      def inspect = "#<#{self.class.name} certificates=#{certificates.size}>"
    end

    # Certificate checks with Ruby's OpenSSL (SPEC §11.2 item 7).
    module TLS
      PEM_CERT = /-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----/m
      ALGORITHMS = {"rsaEncryption" => "RSA", "RSASSA-PSS" => "RSA", "id-ecPublicKey" => "ECDSA", "ED25519" => "Ed25519"}.freeze

      Failure = Values::Failure

      module_function

      # Parses every PEM certificate. Returns [certs, failures].
      def parse_certificates(pem, label, failure_code: :certificate_invalid)
        blocks = pem.scan(PEM_CERT)
        # No PEM certificate at all is a malformed file; one that does not
        # parse is an invalid certificate (SPEC §11.2 item 5).
        return [nil, [Failure.new(:file_malformed, "#{label} holds no PEM certificate")]] if blocks.empty?

        certs = []
        blocks.each_with_index do |b, i|
          certs << OpenSSL::X509::Certificate.new(b)
        rescue OpenSSL::X509::CertificateError => e
          return [nil, [Failure.new(failure_code, "#{label}: certificate #{i + 1} cannot be parsed (#{e.message})")]]
        end
        [certs, []]
      end

      def key_algorithm(cert)
        oid = cert.public_key.oid
        ALGORITHMS.fetch(oid, oid)
      rescue OpenSSL::PKey::PKeyError
        "unknown"
      end

      # Checks a key pair. Returns [TLSMaterial or nil, failures].
      def check(cert_pem:, key_pem:, ca_pem:, dns_names: nil, key_algorithms: nil, min_remaining: nil,
        require_ca: false, now: Time.now)
        failures = []
        chain, f = parse_certificates(cert_pem, "tls.crt")
        failures.concat(f)
        key = begin
          OpenSSL::PKey.read(key_pem)
        rescue OpenSSL::PKey::PKeyError, ArgumentError
          # The parser's message could quote key material; keep it generic.
          code = key_pem.to_s.include?("-----BEGIN") ? :certificate_invalid : :file_malformed
          failures << Failure.new(code, "tls.key is not a readable PEM private key")
          nil
        end
        return [nil, failures] unless chain

        leaf = chain.first
        if key && !leaf.check_private_key(key)
          failures << Failure.new(:key_mismatch, "tls.key does not match the certificate in tls.crt")
        end

        valid_now = true
        if now < leaf.not_before
          valid_now = false
          failures << Failure.new(:certificate_invalid, "certificate is not valid until #{leaf.not_before.utc.iso8601}")
        elsif now > leaf.not_after
          valid_now = false
          failures << Failure.new(:certificate_invalid, "certificate expired at #{leaf.not_after.utc.iso8601}")
        elsif min_remaining
          min = Duration.parse_go(min_remaining) / 1_000_000_000.0
          if leaf.not_after - now < min
            failures << Failure.new(:certificate_expiring,
              "certificate expires at #{leaf.not_after.utc.iso8601}, less than #{min_remaining} from now")
          end
        end

        Array(dns_names).each do |name|
          unless OpenSSL::SSL.verify_certificate_identity(leaf, name)
            failures << Failure.new(:certificate_name_mismatch, "certificate does not cover #{name}")
          end
        end

        if key_algorithms && !key_algorithms.empty?
          alg = key_algorithm(leaf)
          unless key_algorithms.include?(alg)
            failures << Failure.new(:certificate_invalid, "key algorithm #{alg} is not one of #{key_algorithms.join(", ")}")
          end
        end

        # tls.crt must be ordered leaf first, each certificate issued by the next.
        chain.each_cons(2).with_index do |(c, issuer), i|
          next if c.issuer.to_der == issuer.subject.to_der && c.verify(issuer.public_key)

          failures << Failure.new(:certificate_invalid,
            "tls.crt: certificate #{i + 1} is not issued by certificate #{i + 2}; order the chain leaf first")
          break
        end

        cas = nil
        if require_ca
          if ca_pem.nil?
            failures << Failure.new(:file_missing, "ca.crt is required (require_ca) but missing")
          else
            cas, f = parse_certificates(ca_pem, "ca.crt")
            failures.concat(f)
            if cas
              store = OpenSSL::X509::Store.new
              cas.each { |c| store.add_cert(c) }
              # The leaf's own expiry is reported above; do not report it
              # again as a chain error.
              if valid_now
                store.time = now
              else
                store.flags = OpenSSL::X509::V_FLAG_NO_CHECK_TIME
              end
              unless store.verify(leaf, chain[1..])
                failures << Failure.new(:certificate_invalid, "tls.crt does not chain to ca.crt: #{store.error_string}")
              end
            end
          end
        elsif ca_pem
          cas, = parse_certificates(ca_pem, "ca.crt")
        end

        return [nil, failures] unless failures.empty? && key

        [TLSMaterial.new(cert_pem: cert_pem, key_pem: key_pem, ca_pem: ca_pem, chain: chain, key: key,
          ca_certificates: cas), []]
      end
    end
  end
end
