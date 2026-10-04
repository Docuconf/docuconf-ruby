# frozen_string_literal: true

require "openssl"

# Generates real keys and certificates for the TLS tests.
module CertHelper
  DAY = 86_400

  def self.cache
    @cache ||= {}
  end

  def make_key(alg = :ec)
    case alg
    when :rsa then CertHelper.cache[:rsa] ||= OpenSSL::PKey::RSA.new(2048)
    when :rsa2 then CertHelper.cache[:rsa2] ||= OpenSSL::PKey::RSA.new(2048)
    when :ec then OpenSSL::PKey::EC.generate("prime256v1")
    when :ed25519 then OpenSSL::PKey.generate_key("ED25519")
    end
  end

  def make_cert(cn:, key:, issuer: nil, issuer_key: nil, dns: [], not_before: Time.now - 3600,
    not_after: Time.now + (90 * DAY), ca: false)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = rand(1..(2**62))
    cert.subject = OpenSSL::X509::Name.parse("/CN=#{cn}")
    cert.issuer = issuer ? issuer.subject : cert.subject
    cert.public_key = key
    cert.not_before = not_before
    cert.not_after = not_after
    ef = OpenSSL::X509::ExtensionFactory.new
    ef.subject_certificate = cert
    ef.issuer_certificate = issuer || cert
    cert.add_extension(ef.create_extension("basicConstraints", ca ? "CA:TRUE" : "CA:FALSE", true))
    cert.add_extension(ef.create_extension("keyUsage", ca ? "keyCertSign,cRLSign" : "digitalSignature,keyEncipherment", true))
    cert.add_extension(ef.create_extension("subjectKeyIdentifier", "hash", false))
    cert.add_extension(ef.create_extension("subjectAltName", dns.map { |d| "DNS:#{d}" }.join(","), false)) unless dns.empty?
    signer = issuer_key || key
    digest = signer.oid == "ED25519" ? nil : OpenSSL::Digest.new("SHA256")
    cert.sign(signer, digest)
    cert
  end

  # A CA and a leaf signed by it.
  def make_pki(dns: %w[gateway.internal api.example.com], leaf_alg: :ec, **leaf_opts)
    ca_key = make_key(:rsa)
    ca = CertHelper.cache[:ca] ||= make_cert(cn: "Test CA", key: ca_key, ca: true, not_after: Time.now + (3650 * DAY))
    key = make_key(leaf_alg)
    leaf = make_cert(cn: dns.first || "leaf", key: key, issuer: ca, issuer_key: ca_key, dns: dns, **leaf_opts)
    {ca: ca, ca_key: ca_key, cert: leaf, key: key}
  end

  def write_tls(root, dir, pki, ca: true)
    write_file(root, "#{dir}/tls.crt", pki[:cert].to_pem)
    write_file(root, "#{dir}/tls.key", pki[:key].private_to_pem)
    write_file(root, "#{dir}/ca.crt", pki[:ca].to_pem) if ca
  end
end
