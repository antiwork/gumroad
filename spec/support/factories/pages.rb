# frozen_string_literal: true

FactoryBot.define do
  factory :page do
    association :user
    sequence(:title) { |n| "Landing page #{n}" }

    factory :published_page do
      published { true }
      published_at { Time.current }
    end

    factory :profile_page do
      is_profile { true }
      title { "Profile" }
    end
  end

  factory :page_version do
    association :page
    html { "<section><h1>Hello</h1></section>" }
    prompt { "Generate a hello page" }
  end
end
