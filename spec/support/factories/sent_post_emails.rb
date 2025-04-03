# frozen_string_literal: true

FactoryBot.define do
  factory :sent_post_email do
    post
    email { generate(:email) }
  end
end
