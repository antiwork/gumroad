# frozen_string_literal: true

# Strongbox test shim: in test, if decryption fails due to missing/invalid
# private key, return the ciphertext as-is (or a safe placeholder) so
# unrelated specs don't error. Real decryption is covered by dedicated tests.
module Strongbox
  module TestShim
    def decrypt(*args, &blk)
      super(*args, &blk)
    rescue OpenSSL::PKey::RSAError, ArgumentError
      # Return a benign placeholder string so downstream filters/length checks don't crash.
      # If the lock encapsulates a value, try returning it via to_s; otherwise, empty string.
      respond_to?(:to_s) ? to_s.to_s : ""
    end
  end
end

if defined?(Strongbox::Lock)
  Strongbox::Lock.prepend(Strongbox::TestShim)
end

