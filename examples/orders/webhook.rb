# frozen_string_literal: true

require "openssl"

# Checks the signature on incoming payment webhooks against the key set in
# WEBHOOK_KEYS.
module Webhook
  module_function

  # Whether +signature+, the hex HMAC-SHA256 of +body+, was made with any key
  # in +keys+ (a Docuconf::Anyway::KeySet, or nil when WEBHOOK_KEYS is unset).
  # Accepting every key in the set is what lets a key be rotated: during the
  # overlap the old and the new key both work. KeySet#verify tries every
  # key, so the time taken does not say which one matched.
  def verify(keys, body, signature)
    return false if keys.nil? || signature.nil?

    keys.verify do |key|
      OpenSSL.secure_compare(OpenSSL::HMAC.hexdigest("SHA256", key, body), signature.to_s.downcase)
    end
  end
end
