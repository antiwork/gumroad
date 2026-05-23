# frozen_string_literal: true

FactoryBot.define do
  factory :media_location do
    product_id { create(:product).id }
    product_file_id { create(:product_file, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/billion-dollar-company-chapter-0.pdf").id }
    url_redirect_id { create(:url_redirect).id }
    purchase_id { create(:purchase).id }
    platform { Platform::WEB }
    consumed_at { Time.current }
    location { 0 }
  end
end
