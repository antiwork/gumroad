# frozen_string_literal: true

FactoryBot.define do
  factory :subtitle_file do
    product_file
    url { "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/#{SecureRandom.hex}.srt" }
    language { "English" }
  end
end
