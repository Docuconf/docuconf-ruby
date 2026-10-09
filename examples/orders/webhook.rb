# frozen_string_literal: true

require "openssl"

# Checks the signature on incoming payment webhooks against the key set in
# WEBHOOK_KEYS.
module Webhook
  module_function

  # Whether +signature+, the hex HMAC-SHA256 of +body+, was made with any of
  # +keys+. Accepting every key in the set is what lets a key be rotated:
  # during the overlap the old and the new key both work.
  def verify(keys, body, signature)
    Array(keys).reduce(false) do |ok, key|
      want = OpenSSL::HMAC.hexdigest("SHA256", key, body)
      # Check every key, so the time taken does not say which one matched.
      OpenSSL.secure_compare(want, signature.to_s.downcase) || ok
    end
  end
end
