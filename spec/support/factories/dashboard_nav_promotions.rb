# frozen_string_literal: true

FactoryBot.define do
  factory :dashboard_nav_promotion do
    user
    nav_item { "workflows" }
  end
end
