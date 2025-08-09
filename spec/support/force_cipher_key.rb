# frozen_string_literal: true

module ObfuscateIds
  remove_const(:CIPHER_KEY) if const_defined?(:CIPHER_KEY)
  remove_const(:CIPHER_IV)  if const_defined?(:CIPHER_IV)

  CIPHER_KEY = "test-cipher-key"
  CIPHER_IV  = "0000000000000000"
end
