# frozen_string_literal: true

class Purchase::FixLaterChargePresentmentService
  include CurrencyHelper

  attr_reader :purchase, :locked_quote

  def self.canonical_line_items_for(purchases)
    purchases.filter_map do |purchase|
      next if kind_for(purchase).blank?

      {
        permalink: purchase.link.unique_permalink,
        canonical_price_cents: canonical_price_cents_for(purchase),
      }
    end
  end

  def self.kind_for(purchase)
    if purchase.is_preorder_authorization?
      "preorder"
    elsif purchase.is_commission_deposit_purchase?
      "commission"
    elsif purchase.is_installment_payment?
      "installment"
    elsif purchase.link.is_recurring_billing? && purchase.is_original_subscription_purchase?
      "subscription"
    end
  end

  def self.canonical_price_cents_for(purchase)
    if purchase.is_installment_payment?
      payment_option = purchase.subscription&.last_payment_option
      payments = if payment_option&.installment_plan_snapshot.present?
        payment_option.installment_plan_snapshot.calculate_installment_payment_price_cents
      else
        plan = purchase.installment_plan || purchase.link.installment_plan
        plan&.calculate_installment_payment_price_cents(purchase.total_price_before_installments.to_i)
      end
      return payments&.last.to_i
    end

    LaterChargePresentment.canonical_price_cents_for(purchase)
  end

  def initialize(purchase:, locked_quote: nil)
    @purchase = purchase
    @locked_quote = locked_quote
  end

  def perform
    owner = later_charge_owner
    # This service only has checkout terms, so it writes the first fixing. Direct-listed
    # required-currency renewals are re-fixed from their renewal terms by the charge path.
    return if owner.blank? || owner.later_charge_presentments.exists?
    return if purchase.is_gift_sender_purchase?

    canonical_price_cents = self.class.canonical_price_cents_for(purchase)
    return unless canonical_price_cents.positive?

    currency, fx_rate, presentment_price_cents = presentment_terms(canonical_price_cents)
    return if currency.blank? || !fx_rate&.positive? || !presentment_price_cents.to_i.positive?

    owner.later_charge_presentments.create!(
      processor: StripeChargeProcessor.charge_processor_id,
      presentment_currency: currency,
      presentment_price_cents:,
      canonical_price_cents:,
      signup_currency_units_per_usd: 1 / fx_rate,
      effective_from: Time.current
    )
  rescue StandardError => e
    Rails.logger.warn("Could not fix later-charge presentment for purchase #{purchase.id}: #{e.message}")
    ErrorNotifier.notify(e, purchase_id: purchase.id)
    nil
  end

  private
    def later_charge_owner
      case self.class.kind_for(purchase)
      when "preorder"
        purchase.preorder
      when "commission"
        purchase.commission || Commission.find_by(deposit_purchase: purchase)
      when "installment", "subscription"
        purchase.subscription
      end
    end

    def presentment_terms(canonical_price_cents)
      if locked_quote.present?
        metadata = locked_quote.later_charge_presentments.find do |entry|
          (entry["permalink"] || entry[:permalink]).to_s == purchase.link.unique_permalink
        end
        return if metadata.blank?

        presentment_price_cents = metadata["presentment_price_cents"] || metadata[:presentment_price_cents]
        return [locked_quote.currency, locked_quote.fx_rate, presentment_price_cents.to_i]
      end

      presentment = purchase.purchase_presentment
      return if presentment.blank?

      fx_rate = presentment.charge_presentment&.fx_rate&.to_d
      if fx_rate.blank?
        # A product already listed in the presentment currency does not need a Stripe FX
        # quote. Its stored product rate points in the opposite direction from a quote, so
        # invert it here and let #perform keep its single units-per-dollar write convention.
        return unless purchase.link.price_currency_type.to_s.downcase == presentment.presentment_currency

        currency_units_per_usd = purchase.rate_converted_to_usd&.to_d
        return unless currency_units_per_usd&.positive?

        fx_rate = 1 / currency_units_per_usd
      end

      presentment_price_cents = if purchase.is_installment_payment?
        presentment_cents_for(canonical_price_cents, fx_rate, presentment.presentment_currency)
      else
        presentment.presentment_price_cents
      end
      [presentment.presentment_currency, fx_rate, presentment_price_cents]
    end

    def presentment_cents_for(canonical_usd_cents, fx_rate, currency)
      ((BigDecimal(canonical_usd_cents.to_s) / subunit_to_unit(Currency::USD)) / fx_rate * subunit_to_unit(currency)).round
    end
end
