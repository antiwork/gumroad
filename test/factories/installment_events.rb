# frozen_string_literal: true

FactoryBot.define do
  factory :installment_event do
    installment
    event
  end
end
