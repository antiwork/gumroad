# frozen_string_literal: true

module PaymentsHelper
  def create_payment_with_purchase(seller, created_at_date, payment_type = :payment_completed, product: nil, amount_cents: nil, ip_country: nil)
    amount_cents ||= [1000, 2000, 1500].sample
    product ||= create(:product, user: seller)
    payment = create(
      payment_type,
      user: seller,
      amount_cents:,
      payout_period_end_date: created_at_date,
      created_at: created_at_date
    )
    purchase = create(
      :purchase,
      seller:,
      price_cents: amount_cents,
      total_transaction_cents: amount_cents,
      purchase_success_balance: create(:balance, payments: [payment]),
      created_at: created_at_date,
      succeeded_at: created_at_date,
      ip_country:,
      link: product
    )
    payment.amount_cents = purchase.total_transaction_cents
    payment.save!
    { payment:, purchase: }
  end
end
