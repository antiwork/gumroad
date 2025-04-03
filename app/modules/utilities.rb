# frozen_string_literal: true

module Utilities
  module_function

  def cors_preview_policy
    preview_policy_document = {
      expiration: (Time.current + 10.minutes).iso8601,
      conditions: [
        { bucket: S3_BUCKET },
        { acl: "public-read" },
        ["starts-with", "$key", ""],
        ["starts-with", "$Content-Type", ""]
      ]
    }.to_json

    Base64.encode64(preview_policy_document).gsub(/\n|\r/, "")
  end

  def cors_preview_signature
    Base64.encode64(
      OpenSSL::HMAC.digest(
        OpenSSL::Digest.new("sha1"), AWS_SECRET_KEY, cors_preview_policy
      )
    ).delete("\n")
  end

  def sign_with_aws_secret_key(to_sign)
    Base64.encode64(
      OpenSSL::HMAC.digest(
        OpenSSL::Digest.new("sha1"), AWS_SECRET_KEY, to_sign
      )
    ).delete("\n")
  end
end
