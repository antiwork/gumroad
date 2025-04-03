# frozen_string_literal: true

class GumroadDailyAnalyticsCompiler
  class << self
    def compile_gumroad_price_cents(between: nil)
      paid_purchases_between(between:)
        .sum(:price_cents)
    end

    def compile_gumroad_fee_cents(between: nil)
      purchase_cents = paid_purchases_between(between:)
        .sum(:fee_cents)
      service_cents = service_charges_between(between:)
        .sum(:charge_cents)

      purchase_cents + service_cents
    end

    def compile_creators_with_sales(between: nil)
      User
        .not_suspended
        .joins(:sales)
        .merge(paid_purchases_between(between:))
        .where("purchases.price_cents >= ?", 100)
        .count("distinct users.id")
    end

    def compile_gumroad_discover_price_cents(between: nil)
      paid_purchases_between(between:)
        .was_product_recommended
        .sum(:price_cents)
    end

    private
      def paid_purchases_between(between:)
        Purchase
          .paid
          .created_between(between)
      end

      def service_charges_between(between:)
        ServiceCharge
          .successful
          .not_refunded
          .created_between(between)
      end
  end
end
