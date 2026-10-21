# frozen_string_literal: true

FactoryBot.define do
  factory :product_file_download_grant do
    url_redirect
    product_file { association :product_file, link: url_redirect.referenced_link, stream_only: true }
  end
end
