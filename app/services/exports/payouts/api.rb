# frozen_string_literal: true

class Exports::Payouts::Api < Exports::Payouts::Base
  include CurrencyHelper

  HEADERS = %w[type date purchase_id item_name buyer_name buyer_email taxes shipping sale_price gumroad_fees net_total]

  def initialize(payment)
    @payment = payment
  end

  def perform
    payout_data.map { HEADERS.zip(_1).to_h }
  end
end
