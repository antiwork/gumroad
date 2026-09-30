# frozen_string_literal: true

FactoryBot.define do
  factory :piracy_report do
    seller { association :user }
    product { association :product, user: seller }
    source { "dashboard" }
    url { "https://example.net/design-course" }

    trait :screening do
      state { "screening" }
    end

    trait :awaiting_signature do
      state { "awaiting_signature" }
      screening_verdict { "pass" }
      recipient_name { "Example Net Inc." }
      recipient_email { "copyright@example.net" }
      recipient_source_url { "https://dmca.copyright.gov/osp/example" }
      notice_text { "Notice text" }
      notice_digest { Digest::SHA256.hexdigest("Notice text") }
    end
  end
end
