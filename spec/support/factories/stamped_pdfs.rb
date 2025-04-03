# frozen_string_literal: true

FactoryBot.define do
  factory :stamped_pdf do
    url_redirect
    product_file
    url { "https://s3.amazonaws.com/gumroad-specs/attachment/manual_stamped.pdf" }
  end
end
