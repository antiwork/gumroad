# frozen_string_literal: true

FactoryBot.define do
  # The text a signed report carries: the notice with the signature line already in it, and the
  # digest taken over that text.
  signed_notice_text = "Notice text\n\nSigned: /s/ Example Seller, January 1, 2026\n"

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
      recipient_email { "copyright@example.com" }
      recipient_source_url { "https://dmca.copyright.gov/osp/example" }
      notice_text { "Notice text" }
      notice_digest { Digest::SHA256.hexdigest("Notice text") }
    end

    trait :signed do
      state { "signed" }
      screening_verdict { "pass" }
      recipient_name { "Example Net Inc." }
      recipient_email { "copyright@example.com" }
      recipient_source_url { "https://dmca.copyright.gov/osp/example" }
      notice_text { signed_notice_text }
      notice_digest { Digest::SHA256.hexdigest(signed_notice_text) }
      signed_by_name { "Example Seller" }
      signed_at { Time.current }
      signed_ip { "203.0.113.7" }
      signature_statement_version { PiracyReport::SIGNATURE_STATEMENT_VERSION }
    end

    # What the row looks like after the notice has gone out. The reply token is unique per row.
    trait :sent do
      signed
      state { "sent" }
      sent_at { Time.current }
      sent_to_email { "copyright@example.com" }
      final_notice_digest { Digest::SHA256.hexdigest(signed_notice_text) }
      delivery_status { "sent" }
      sent_message_id { "message-id@example.com" }
      reply_token { SecureRandom.urlsafe_base64(PiracyReport::REPLY_TOKEN_LENGTH) }
    end
  end
end
