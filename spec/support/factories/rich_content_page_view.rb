# frozen_string_literal: true

FactoryBot.define do
  factory :rich_content_page_view do
    association :rich_content
    association :purchase
    association :product, factory: :product
    association :buyer, factory: :user
    url_redirect_id { "test_redirect_#{rand(1000)}" }
    ip_address { "192.168.1.#{rand(1..255)}" }
    user_agent { "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/91.0" }
    viewed_at { Time.current }
  end
end
