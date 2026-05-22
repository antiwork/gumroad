# frozen_string_literal: true

FactoryBot.define do
  factory :page do
    association :user
    sequence(:title) { |n| "Landing page #{n}" }
    # Default to a profile-owned page so the default factory satisfies the
    # must_have_owner validation. Override with `link: product` or set
    # `is_profile: false` + `link: ...` when testing product-owned pages.
    is_profile { true }

    factory :published_page do
      published { true }
      published_at { Time.current }
    end

    factory :profile_page do
      is_profile { true }
      title { "Profile" }
    end

    factory :product_page do
      is_profile { false }
      association :link, factory: :product
    end
  end

  factory :page_version do
    association :page
    html { "<section><h1>Hello</h1></section>" }
    prompt { "Generate a hello page" }
  end
end
