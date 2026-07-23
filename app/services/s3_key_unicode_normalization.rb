# frozen_string_literal: true

# S3 object keys are compared byte-for-byte, but the same accented filename can be encoded in
# more than one valid way in Unicode: for example "é" can be a single precomposed character
# (NFC form) or an "e" followed by a combining accent mark (NFD form, which is what macOS
# produces when uploading files). When the key we persisted in the database uses a different
# normalization form than the actual object key in S3, lookups raise Aws::S3::Errors::NotFound
# even though the file is really there — and the seller is wrongly told their file is gone.
#
# This module computes the alternative normalization forms of a key and finds the one that
# actually exists in the bucket, so callers can fall back to it instead of failing.
module S3KeyUnicodeNormalization
  extend self

  NORMALIZATION_FORMS = [:nfd, :nfc].freeze

  # Returns the first Unicode-normalization variant of `s3_key` (different from `s3_key`
  # itself) that exists in the bucket, or nil when none do. For plain-ASCII keys there are no
  # variants, so this makes no S3 calls at all — genuinely missing objects still fail fast.
  def existing_variant(s3_key, bucket: S3_BUCKET)
    variants(s3_key).find do |variant|
      Aws::S3::Resource.new.bucket(bucket).object(variant).exists?
    end
  end

  # The distinct normalization forms of `s3_key`, excluding `s3_key` itself. Returns an empty
  # array for keys that cannot be Unicode-normalized (e.g. binary or invalid encodings).
  def variants(s3_key)
    NORMALIZATION_FORMS.filter_map do |form|
      variant = s3_key.unicode_normalize(form)
      variant unless variant == s3_key
    end
  rescue ArgumentError, EncodingError
    []
  end
end
