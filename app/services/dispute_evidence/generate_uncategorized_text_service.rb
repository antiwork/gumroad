# frozen_string_literal: true

class DisputeEvidence::GenerateUncategorizedTextService
  def self.perform(purchase)
    new(purchase).perform
  end

  include ActionView::Helpers::NumberHelper

  attr_reader :purchase

  def initialize(purchase)
    @purchase = purchase
  end

  def perform
    rows = [
      customer_location_text,
      billing_zip_text,
      previous_purchases_rows
    ].compact
    rows.flatten.join("\n")
  end

  private
    def customer_location_text
      return if purchase.ip_state.blank?

      "Device location: #{purchase.ip_state}, #{purchase.ip_country}"
    end

    def billing_zip_text
      return if purchase.credit_card_zipcode.blank?

      "Billing postal code: #{purchase.credit_card_zipcode}"
    end

    # Evidence of one or more non-disputed payments on the same card
    def previous_purchases_rows
      previous_purchases = find_previous_purchases
      return if previous_purchases.none?

      rows = []
      rows << "\nPrevious undisputed #{"purchase".pluralize(previous_purchases.count)} on Gumroad:"
      previous_purchases.each do |other_purchase|
        rows << previous_purchases_text(other_purchase)
      end
      rows
    end

    def previous_purchases_text(other_purchase)
      device_location = build_device_location(other_purchase)
      [
        other_purchase.created_at,
        MoneyFormatter.format(other_purchase.total_transaction_cents, :usd),
        other_purchase.full_name&.strip,
        other_purchase.email,
        ("Billing postal code: #{other_purchase.credit_card_zipcode}" if other_purchase.credit_card_zipcode.present?),
        ("Device location: #{device_location}" if device_location.present?),
      ].compact.join(", ")
    end

    def build_device_location(purchase)
      [purchase.ip_address, purchase.ip_state, purchase.ip_country].compact.join(", ").presence
    end

    def find_previous_purchases
      Purchase.successful
        .not_fully_refunded
        .not_chargedback
        .where(stripe_fingerprint: purchase.stripe_fingerprint)
        .where.not(id: purchase.id)
        .order(created_at: :desc)
        .limit(10)
    end
end
