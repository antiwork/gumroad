# frozen_string_literal: true

FactoryBot.define do
  factory :url_redirect do
    purchase { create(:purchase, purchaser: create(:named_user), link:) }
    association :link, factory: :product
    uses { 0 }
    expires_at { "2012-01-11 12:46:23" }

    factory :streamable_url_redirect do
      after(:create) do |url_redirect|
        create(:streamable_video, :analyze, link: url_redirect.referenced_link)
      end
    end

    factory :readable_url_redirect do
      after(:create) do |url_redirect|
        create(:readable_document, :analyze, link: url_redirect.referenced_link)
      end
    end

    factory :listenable_url_redirect do
      after(:create) do |url_redirect|
        create(:listenable_audio, :analyze, link: url_redirect.referenced_link)
      end
    end
  end

  factory :installment_url_redirect, class: UrlRedirect do
    installment
    uses { 0 }
    expires_at { "2012-01-11 12:46:23" }
  end
end
