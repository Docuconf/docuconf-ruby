# frozen_string_literal: true

require "openssl"
require "json"

module Docuconf
  module Anyway
    # A set of secret keys that are all valid at once, so a key can be
    # rotated without an outage (contract type "keySet", SPEC §4.3 and
    # §6.1). It is for the side that verifies: webhook signatures, inbound
    # API keys, JWT HMAC verification, cookie-signing fallbacks.
    #
    #   describe :webhook_keys, "Keys that verify webhook signatures",
    #     type: :key_set, key_min_length: 32, key_max_length: 256
    #
    #   config.webhook_keys.verify { |key| OpenSSL.secure_compare(hmac(key, body), signature) }
    #   config.api_keys.contains?(request.headers["X-Api-Key"])
    #
    # A key set is always secret: #inspect, #to_s, #to_json and pp show
    # [FILTERED], never a key. Its keys keep the order the platform gave
    # them (during a rotation, old then new).
    class KeySet
      FILTERED = "[FILTERED]"

      # keys: an Array of Strings, in order.
      def initialize(keys)
        unless keys.is_a?(Array) && keys.all?(String)
          raise ArgumentError, "a KeySet holds an Array of String keys"
        end

        @keys = keys.map { |k| k.dup.freeze }.freeze
        freeze
      end

      # The keys, in the order the platform gave them.
      def keys = @keys.dup

      def size = @keys.size
      alias_method :length, :size

      def empty? = @keys.empty?

      # Whether candidate is one of the keys, such as an API key a caller
      # presents. It compares candidate with every key in constant time
      # (OpenSSL.secure_compare), so the time taken says neither which key
      # matched nor how much of one.
      def contains?(candidate)
        return false unless candidate.is_a?(String)

        @keys.reduce(false) { |found, key| OpenSSL.secure_compare(key, candidate) | found }
      end
      alias_method :include?, :contains?

      # Calls the block with each key and returns whether any call returned
      # true. It is for checks that need the key itself, such as an HMAC:
      #
      #   keys.verify do |key|
      #     OpenSSL.secure_compare(OpenSSL::HMAC.hexdigest("SHA256", key, body), signature)
      #   end
      #
      # Every key is tried, even after one matches, so the time taken does
      # not say which key matched. The block should compare in constant time
      # itself, as OpenSSL.secure_compare does.
      def verify
        raise ArgumentError, "KeySet#verify needs a block" unless block_given?

        @keys.reduce(false) { |ok, key| (yield(key) ? true : false) | ok }
      end

      def ==(other) = other.is_a?(KeySet) && other.size == size && other.keys.zip(@keys).all? { |a, b| OpenSSL.secure_compare(a, b) }
      alias_method :eql?, :==

      def hash = [self.class, @keys].hash

      def to_s = FILTERED
      def inspect = "#<#{self.class.name} #{FILTERED}>"

      def pretty_print(q) = q.text(inspect)

      def as_json(*) = FILTERED

      def to_json(*args) = FILTERED.to_json(*args)
    end
  end
end
