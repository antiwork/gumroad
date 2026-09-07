# frozen_string_literal: true

FactoryBot.define do
  factory :user_instagram_identity do
    user
    sequence(:instagram_user_id) { "178414#{_1.to_s.rjust(11, "0")}" }
    handle { "gumroad" }
  end
end
