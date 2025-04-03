# frozen_string_literal: true

FactoryBot.define do
  factory :tos_agreement do
    user
    ip { "54.234.242.13" }
  end
end
