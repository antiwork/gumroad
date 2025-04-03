# frozen_string_literal: true

module Purchase::Reportable
  extend ActiveSupport::Concern

  def price_cents_net_of_refunds
    net_of_refunds_cents(:price_cents, :amount_cents)
  end

  def fee_cents_net_of_refunds
    net_of_refunds_cents(:fee_cents, :fee_cents)
  end

  def tax_cents_net_of_refunds
    net_of_refunds_cents(:tax_cents, :creator_tax_cents)
  end

  def gumroad_tax_cents_net_of_refunds
    net_of_refunds_cents(:gumroad_tax_cents, :gumroad_tax_cents)
  end

  def total_cents_net_of_refunds
    net_of_refunds_cents(:total_transaction_cents, :total_transaction_cents)
  end

  private
    def net_of_refunds_cents(purchase_attribute, refund_attribute)
      # Fully refunded or Chargebacked not reversed
      return 0 if chargedback_not_reversed_or_refunded?
      # No chargeback or refunds
      return self.send(purchase_attribute) unless stripe_partially_refunded? || chargedback_not_reversed_or_refunded?
      refunded_cents = refunds.sum(refund_attribute)
      # No refunded amount
      return self.send(purchase_attribute) unless refunded_cents > 0
      # Partially refunded amount
      net_cents = self.send(purchase_attribute) - refunded_cents
      return net_cents if net_cents > 0
      Rails.logger.info "Unknown #{purchase_attribute} for purchase: #{self.id}"
      # Something is wrong, we have more refunds than actual collection of fees, just ignore
      0
    end
end
