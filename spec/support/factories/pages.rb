# frozen_string_literal: true

FactoryBot.define do
  # A first-class slugged page on a seller's storefront. Use `custom_html:`
  # instead of `content:` for the agent/CLI-built full-HTML variant, or
  # `slug: nil` for the root (whole-profile takeover) page.
  factory :user_page, class: "Page" do
    association :pageable, factory: :user
    sequence(:slug) { "page-#{_1}" }
    title { "Page title" }
    content { "<p>Page content</p>" }
  end
end
