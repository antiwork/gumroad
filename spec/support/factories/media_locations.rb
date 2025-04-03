# frozen_string_literal: true

FactoryBot.define do
  factory :media_location do
    product_id { create(:product).id }
    product_file_id { create(:product_file, url: "https://s3.amazonaws.com/gumroad-specs/specs/billion-dollar-company-chapter-0.pdf").id }
    url_redirect_id { create(:url_redirect).id }
    purchase_id { create(:purchase).id }
    platform { Platform::WEB }
    consumed_at { Time.current }
    location { 0 }
  end
end
