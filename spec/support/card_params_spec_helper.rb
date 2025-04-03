# frozen_string_literal: true

# A collection of card parameters for the Stripe payment processor. Use these in preference to hardcoding card numbers
# into tests where possible, and expand as necessary, ensuring that only cards listed in the Stripe testing
# documentation are included in our specs.
# Stripe Test Cards: https://stripe.com/docs/testing
# All card parameter hash's expose card params without zip code data. To add zip code use with_zip_code on the hash.
# All card parameter functions are named such that the first word is 'success' or 'decline' indicating the default
# behavior expected on any action with the payment processor. The following words define what's unqiue about the card
# and what will be different in the format: [context] [action].
# All parameters by default are in the default format of card data handling mode 'stripe'. To get 'stripejs' versions
# use the to_stripejs_params

module CardParamsSpecHelper
  EXPIRY_MM = "12"
  EXPIRY_YYYY = Time.current.strftime("%Y")
  EXPIRY_YY = Time.current.strftime("%y")
  EXPIRY_MMYY = "#{EXPIRY_MM}/#{EXPIRY_YY}"

  module ExtensionMethods
    def to_stripe_card_hash
      expiry_month, expiry_year = CreditCardUtility.extract_month_and_year(self[:expiry_date]) if self[:expiry_date]
      stripe_params = {}
      stripe_params[:number] = self[:cc_number] if self[:cc_number]
      stripe_params[:exp_month] = expiry_month if expiry_month
      stripe_params[:exp_year] = expiry_year if expiry_year
      stripe_params[:cvc] = self[:cvc] if self[:cvc]
      stripe_params[:address_zip] = self[:cc_zipcode] if self[:cc_zipcode]
      stripe_params[:currency] = "usd"
      stripe_params
    end

    def to_stripejs_token_obj
      Stripe::Token.create(card: to_stripe_card_hash)
    end

    def to_stripejs_token
      to_stripejs_token_obj.id
    end

    def to_stripejs_fingerprint
      to_stripejs_token_obj.card.fingerprint
    end

    def to_stripejs_params
      begin
        stripejs_params = {
          card_data_handling_mode: CardDataHandlingMode::TOKENIZE_VIA_STRIPEJS,
          stripe_token: to_stripejs_token
        }
      rescue Stripe::InvalidRequestError, Stripe::APIConnectionError, Stripe::APIError, Stripe::CardError => e
        stripejs_params = CardParamsSpecHelper::StripeJs.build_error(e.json_body[:type], e.json_body[:message], code: e.json_body[:code])
      end
      stripejs_params
    end

    def with_zip_code(zip_code = "12345")
      with(:cc_zipcode, zip_code)
    end

    def with(key, value)
      copy = clone
      copy[key] = value
      copy.extend(ExtensionMethods)
      copy
    end

    def without(key)
      copy = clone
      copy.delete(key)
      copy.extend(ExtensionMethods)
      copy
    end
  end

  class StripeJs
    def self.error_unavailable
      build_error("api_error", "stripe api has gone downnnn")
    end

    def self.build_error(type, message, code: nil)
      {
        card_data_handling_mode: CardDataHandlingMode::TOKENIZE_VIA_STRIPEJS,
        stripe_error: {
          type:,
          message:,
          code:
        }
      }
    end
  end

  module_function

  def build(number: "4242 4242 4242 4242", expiry_month: EXPIRY_MM, expiry_year: EXPIRY_YYYY, cvc: "123")
    card_params = {
      cc_number: number,
      expiry_date: "#{expiry_month} / #{expiry_year}",
      cvc:
    }
    card_params.extend(ExtensionMethods)
    card_params
  end

  def success
    build
  end

  def success_debit_visa
    build(number: "4000 0566 5566 5556")
  end
end
