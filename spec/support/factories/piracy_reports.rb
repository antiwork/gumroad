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
      infringing_urls { [url] }
      recipient_kind { "site" }
      recipient_name { "Example Net" }
      recipient_email { "copyright@example.net" }
      recipient_source_url { "https://example.net/copyright" }
      notice_text { "Notice text" }
      notice_digest { Digest::SHA256.hexdigest("Notice text") }
    end
  end
end
