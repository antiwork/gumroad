# frozen_string_literal: true

module Utilities
  module_function



  def sign_with_aws_secret_key(to_sign)
    Base64.encode64(
      OpenSSL::HMAC.digest(
        OpenSSL::Digest.new("sha1"), AWS_SECRET_KEY, to_sign
      )
    ).delete("\n")
  end
end
