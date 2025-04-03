# frozen_string_literal: true

FactoryBot.define do
  factory :credit_card do
    transient do
      chargeable { build(:chargeable) }
      user { nil }
    end
    initialize_with do
      CreditCard.create(chargeable, nil, user)
    end
  end
end
