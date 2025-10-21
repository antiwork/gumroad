# frozen_string_literal: true

FactoryBot.define do
  factory :stamped_pdf do
    url_redirect
    product_file
    url { "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/manual_stamped.pdf" }
  end
end
