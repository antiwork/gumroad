# frozen_string_literal: true

FactoryBot.define do
  factory :backtax_agreement do
    user
    jurisdiction { "AUSTRALIA" }
    signature { "Edgar Gumstein" }
  end
end
