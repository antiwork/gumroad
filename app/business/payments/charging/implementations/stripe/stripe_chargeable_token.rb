# frozen_string_literal: true

# Public: Chargeable representing pre-tokenized data using Stripe.
class StripeChargeableToken
  include StripeErrorHandler

  attr_reader :payment_method_id

  def initialize(token, zip_code, product_permalink:)
    @token_s = token
    @zip_code = zip_code
    @merchant_account = get_merchant_account(product_permalink)
  end

  def charge_processor_id
    StripeChargeProcessor.charge_processor_id
  end

  def prepare!
    with_stripe_error_handler do
      @token = Stripe::Token.retrieve(@token_s) if card.nil?
    end
    true
  end

  def funding_type
    return card[:funding] if card.present? && card[:funding].present?

    nil
  end

  def fingerprint
    return card[:fingerprint] if card.present? && card[:fingerprint].present?

    nil
  end

  def last4
    return card[:last4] if card.present? && card[:last4].present?

    nil
  end

  def number_length
    return ChargeableVisual.get_card_length_from_card_type(card_type) if card_type

    nil
  end

  def visual
    return ChargeableVisual.build_visual(last4, number_length) if last4.present? && number_length.present?

    nil
  end

  def expiry_month
    return card[:exp_month] if card.present? && card[:exp_month].present?

    nil
  end

  def expiry_year
    return card[:exp_year] if card.present? && card[:exp_year].present?

    nil
  end

  def zip_code
    return card[:address_zip] if card.present? && card[:address_zip].present?

    @zip_code
  end

  def card_type
    return StripeCardType.to_card_type(card[:brand]) if card.present? && card[:brand].present?

    nil
  end

  def country
    return card[:country] if card.present? && card[:country].present?

    nil
  end

  def card
    return @customer.sources.first if @customer
    return @token.card if @token.present?

    nil
  end

  def reusable_token!(user)
    if @customer.nil?
      with_stripe_error_handler do
        creation_params = { description: user&.id.to_s, email: user&.email, card: @token_s, expand: %w[sources] }
        @customer = if @merchant_account&.is_a_stripe_connect_account?
          Stripe::Customer.create(creation_params, stripe_account: @merchant_account.charge_processor_merchant_id)
        else
          Stripe::Customer.create(creation_params)
        end
      end
    end
    @customer[:id]
  end

  def stripe_charge_params
    Rails.logger.error "StripeChargeableToken#stripe_charge_params called"
    reusable_token!(nil)
    return { customer: @customer[:id], payment_method: nil } if @customer

    { card: @token_s }
  end

  def requires_mandate?
    country == "IN"
  end

  private
    def get_merchant_account(permalink)
      return unless permalink

      link = Link.find_by unique_permalink: permalink
      link&.user && link.user.merchant_account(StripeChargeProcessor.charge_processor_id)
    end
end
