# frozen_string_literal: true

FactoryBot.define do
  factory :oauth_application do
    sequence(:name) { |n| "app#{n}" }
    redirect_uri { "https://foo" }
    association :owner, factory: :user
    factory :oauth_application_valid do
      factory :oauth_application_with_link do
        after(:create) { |oauth_application| oauth_application.links << FactoryBot.create(:product) }
      end
    end
  end
end
