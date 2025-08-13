# frozen_string_literal: true

class ReceiptPresenter::PaymentInfo
  include ActionView::Helpers::UrlHelper
  include CurrencyHelper

  def initialize(chargeable)
    @chargeable = chargeable
    @orderable = chargeable.orderable
  end

  def present?
    today_payment_attributes.present? || upcoming_payment_attributes.present?
  end

  def title
    # Applies for recurring subscription receipts only
    if chargeable.is_recurring_subscription_charge
      "Thank you for your payment!"
    else
      "Payment info"
    end
  end

  def notes
    [
      recurring_subscription_notes,
      usd_currency_note,
      credit_card_note
    ].flatten.compact
  end

  def today_payment_attributes
    @_today_payment_attributes ||= begin
      return [] if receipt_for_gift_receiver?

      [
        today_payment_heading_attribute,
        today_price_attributes,
        today_shipping_price_attribute,
        today_tax_price_attributes,
        today_total_price_attribute,
        today_membership_paid_until_attribute,
        generate_invoice_attribute,
      ].flatten.compact
    end
  end

  def today_price_attributes
    @_today_price_attributes ||= chargeable
      .successful_purchases
      .map { today_price_attribute(_1) }
      .compact
  end

  def today_shipping_price_attribute
    @_today_shipping_price_attribute ||= begin
      return unless chargeable.shipping_cents > 0

      amount_cents = chargeable.successful_purchases.sum do |purchase|
        purchase.is_free_trial_purchase? ? 0 : purchase.shipping_cents
      end

      {
        label: "Shipping",
        value: formatted_dollar_amount(amount_cents),
      }
    end
  end

  def today_tax_price_attributes
    return unless chargeable.taxable?

    amount_cents = chargeable.successful_purchases.sum do |purchase|
      purchase.is_free_trial_purchase? ? 0 : purchase.non_refunded_tax_amount
    end
    # Show zero for free trials, single-item purchases
    return if amount_cents.zero? && chargeable.multi_item_charge?

    canadian_sales_tax_attributes = [
      {
        label: "GST/HST",
        value: calculate_tax_amount_cents(amount_cents:, tax_rate_field: :gst_tax_rate),
      },
      {
        label: "PST",
        value: calculate_tax_amount_cents(amount_cents:, tax_rate_field: :pst_tax_rate),
      },
      {
        label: "QST",
        value: calculate_tax_amount_cents(amount_cents:, tax_rate_field: :qst_tax_rate),
      },
    ].select { _1[:value].positive? }.map { _1[:value] = formatted_dollar_amount(_1[:value]); _1 }

    total_tax_attribute =
      {
        label: chargeable.tax_label_with_creator_tax_info,
        value: formatted_dollar_amount(amount_cents),
      }

    canadian_sales_tax_attributes.presence || [total_tax_attribute]
  end

  def upcoming_payment_attributes
    @_upcoming_payment_attributes ||= begin
      return [] unless any_upcoming_payments?
      return [] if receipt_for_gift_receiver? || receipt_for_gift_sender?

      [
        upcoming_payment_heading_attribute,
        upcoming_price_attributes,
      ].flatten.compact
    end
  end

  def payment_method_attribute
    @_payment_method_attribute ||= begin
      return if chargeable.successful_purchases.all?(&:is_free_trial_purchase?)
      return if orderable.card_type.blank? && orderable.card_visual.blank?

      {
        label: "Payment method",
        value: "#{orderable.card_type.upcase} *#{orderable.card_visual.delete('*').delete(' ')}"
      }
    end
  end

  private
    attr_reader :chargeable, :orderable

    def recurring_subscription_notes
      # This is only used for recurring subscription receipts, so technically chargeable is a Purchase
      chargeable.successful_purchases.filter_map do |purchase|
        return unless purchase.is_recurring_subscription_charge

        product = purchase.link
        link_to_product = link_to(product.name, product.long_url, target: "_blank")

        if purchase.is_installment_payment?
          "We have successfully processed the installment payment for #{link_to_product}.".html_safe
        else
          "We have successfully processed the payment for your recurring subscription to #{link_to_product}.".html_safe
        end
      end
    end

    def usd_currency_note
      "All charges are processed in United States Dollars. Your bank or financial institution may apply their own fees for currency conversion."
    end

    def credit_card_note
      return if orderable.card_type.blank?
      return if orderable.card_type == CardType::PAYPAL

      # TODO: Update when multiple charges per receipt are supported
      "The charge will be listed as GUMRD.COM* on your credit card statement."
    end

    def today_payment_heading_attribute
      return unless any_upcoming_payments?

      {
        label: "Today's payment",
        value: nil
      }
    end

    def any_upcoming_payments?
      upcoming_price_attributes.present? && !receipt_for_gift_sender?
    end

    def today_price_attribute(purchase)
      return if purchase.free_purchase? && !purchase.is_free_trial_purchase?

      amount_cents = 0
      if !purchase.is_free_trial_purchase?
        amount_cents = get_usd_cents(
          purchase.displayed_price_currency_type,
          purchase.displayed_price_cents,
          rate: purchase.rate_converted_to_usd
        )
      end

      {
        label: price_attribute_label(purchase) + today_price_attribute_label_notes(purchase),
        value: formatted_dollar_amount(amount_cents) + today_price_attribute_value_notes(purchase),
      }
    end

    def price_attribute_label(purchase)
      product = purchase.link

      if purchase.quantity <= 1
        product.name
      else
        "#{product.name} × #{purchase.quantity}"
      end
    end

    def today_price_attribute_label_notes(purchase)
      if purchase.subscription.present?
        subscription_charge_progress(purchase).to_s
      else
        ""
      end
    end

    def upcoming_price_attribute_label_notes(purchase)
      if purchase.subscription.present?
        upcoming_subscription_charge_progress(purchase).to_s
      else
        ""
      end
    end

    def today_price_attribute_value_notes(purchase)
      if purchase.subscription.present?
        final_subscription_charge_note(purchase).to_s
      else
        ""
      end
    end

    def final_subscription_charge_note(purchase)
      return unless purchase.subscription.charges_completed?
      return unless purchase == purchase.subscription.last_purchase

      " - This is the final payment. You will not be charged for this product again."
    end

    def today_total_price_attribute
      return if \
        chargeable.successful_purchases.one? &&
        today_shipping_price_attribute.blank? &&
        today_tax_price_attributes.blank?

      amount_cents = chargeable.successful_purchases.sum do |purchase|
        purchase.is_free_trial_purchase? ? 0 : purchase.total_transaction_cents
      end
      {
        label: "Amount paid",
        value: formatted_dollar_amount(amount_cents),
      }
    end

    def generate_invoice_attribute
      return unless chargeable.has_invoice?

      {
        label: nil,
        value: link_to("Generate invoice", chargeable.invoice_url)
      }
    end

    def upcoming_payment_heading_attribute
      {
        label: "Upcoming #{"payment".pluralize(upcoming_price_attributes.size)}",
        value: nil
      }
    end

    def today_membership_paid_until_attribute
      return unless receipt_for_gift_sender? && chargeable.subscription

      subscription = chargeable.subscription

      {
        label: "Membership paid for until",
        value: subscription.end_time_of_subscription.to_fs(:formatted_date_abbrev_month)
      }
    end

    def receipt_for_gift_receiver?
      orderable.receipt_for_gift_receiver?
    rescue NotImplementedError
      false
    end

    def receipt_for_gift_sender?
      orderable.receipt_for_gift_sender?
    rescue NotImplementedError
      false
    end

    def upcoming_price_attributes
      @_upcoming_price_attributes ||= chargeable
        .successful_purchases
        .select { _1.subscription.present? || _1.is_commission_deposit_purchase? }
        .compact
        .map { upcoming_price_attribute(_1) }
        .compact
    end

    def upcoming_price_attribute(purchase)
      if purchase.is_commission_deposit_purchase?
        {
          label: price_attribute_label(purchase),
          value: "#{formatted_price(
              purchase.displayed_price_currency_type,
              purchase.commission.completion_price_cents
            )} on completion".html_safe
        }
      else
        subscription = purchase.subscription
        return if subscription.has_fixed_length? && purchase == subscription.last_purchase && subscription.remaining_charges_count&.zero?

        if subscription.current_subscription_price_cents == purchase.displayed_price_cents
          next_payment_tax_cents = purchase.tax_in_purchase_currency
        else
          tax_calculation = SalesTaxCalculator.new(
            product: purchase.link,
            price_cents: subscription.current_subscription_price_cents,
            shipping_cents: purchase.shipping_cents,
            quantity: purchase.quantity,
            buyer_location:
              {
                postal_code: purchase.zip_code,
                country: Compliance::Countries.find_by_name(purchase.country)&.alpha2,
                ip_address: purchase.ip_address
              },
            buyer_vat_id: purchase.business_vat_id, from_discover: purchase.was_product_recommended
          ).calculate
          next_payment_tax_cents = usd_cents_to_currency(
            purchase.link.price_currency_type,
            tax_calculation.tax_cents,
            purchase.rate_converted_to_usd
          )
        end

        next_payment_date = purchase.is_free_trial_purchase? ? subscription.free_trial_ends_at : purchase.created_at + subscription.period
        {
          label: price_attribute_label(purchase) + upcoming_price_attribute_label_notes(purchase),
          value: "#{formatted_price(
              purchase.displayed_price_currency_type,
              subscription.current_subscription_price_cents + purchase.shipping_in_purchase_currency + next_payment_tax_cents
            )} on #{next_payment_date.to_fs(:formatted_date_abbrev_month)}".html_safe
        }
      end
    end

    def calculate_tax_amount_cents(amount_cents:, tax_rate_field:)
      taxjar_info = chargeable.purchase_taxjar_info
      return 0 unless taxjar_info.present?

      tax_rate = taxjar_info.send(tax_rate_field).to_f
      return 0 if tax_rate.zero?

      tax_percent = tax_rate / taxjar_info.combined_tax_rate.to_f
      amount_cents * tax_percent
    end

    def subscription_charge_progress(purchase)
      return unless purchase.subscription.has_fixed_length?

      if purchase.is_free_trial_purchase?
        " (free trial)"
      else
        ": #{subscription_charge_number(purchase)} of #{purchase.subscription.charge_occurrence_count}"
      end
    end

    def upcoming_subscription_charge_progress(purchase)
      return unless purchase.subscription.has_fixed_length?

      ": #{subscription_charge_number(purchase) + 1} of #{purchase.subscription.charge_occurrence_count}"
    end

    def subscription_charge_number(purchase)
      return 0 if purchase.is_free_trial_purchase?

      @_subscription_charge_number ||= {}

      if @_subscription_charge_number.key?(purchase.id)
        @_subscription_charge_number[purchase.id]
      else
        @_subscription_charge_number[purchase.id] = purchase
          .subscription
          .purchases
          .successful
          .where("succeeded_at < ?", purchase.succeeded_at)
          .count + 1
      end
    end
end
