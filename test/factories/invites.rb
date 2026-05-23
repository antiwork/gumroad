# frozen_string_literal: true

FactoryBot.define do
  factory :invite do
    user
    receiver_email { generate :email }
  end
end
