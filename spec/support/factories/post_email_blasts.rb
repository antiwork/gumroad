# frozen_string_literal: true

FactoryBot.define do
  factory :post_email_blast, aliases: [:blast] do
    post
    seller { post.seller }
    requested_at { 30.minutes.ago }
    started_at { 25.minutes.ago }
    first_email_delivered_at { 20.minutes.ago }
    last_email_delivered_at { 10.minutes.ago }
    delivery_count { 1500 }

    trait :just_requested do
      requested_at { Time.current }
      started_at { nil }
      first_email_delivered_at { nil }
      last_email_delivered_at { nil }
      delivery_count { 0 }
    end
  end
end
