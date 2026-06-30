# frozen_string_literal: true

FactoryBot.define do
  factory :purchase_payment_flow do
    purchase
    payment_details_source { PurchasePaymentFlow::PAYMENT_ELEMENT }
    payment_details_transport { PurchasePaymentFlow::PAYMENT_METHOD }
    stripe_payment_method_type { PurchasePaymentFlow::CARD }
  end
end
