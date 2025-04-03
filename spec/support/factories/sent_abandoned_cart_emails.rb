# frozen_string_literal: true

FactoryBot.define do
  factory :sent_abandoned_cart_email do
    cart { create(:cart) }
    installment { create(:abandoned_cart_workflow, published_at: 1.day.ago).installments.first }
  end
end
