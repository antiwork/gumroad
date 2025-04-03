# frozen_string_literal: true

FactoryBot.define do
  factory :third_party_analytic do
    user
    name { "Gumhead's Snippet" }
    link { FactoryBot.create(:product, user:) }
    analytics_code { "<script>console.log('running script')</script><noscript><img height='1' width='1' alt='' style='display:none' src='http://placehold.it/350x150' /></noscript>" }
  end
end
