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
  module ExtensionMethods
    def to_stripe_card_hash
      stripe_params = { token: self[:token] }
      stripe_params[:address_zip] = self[:cc_zipcode] if self[:cc_zipcode]
      stripe_params[:currency] = "usd"
      stripe_params
    end

    def to_stripejs_token_obj
      Stripe::Token.retrieve(self[:token])
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

  def build(token: "tok_visa")
    card_params = {
      token:
    }
    card_params.extend(ExtensionMethods)
    card_params
  end

  def success
    build
  end

  def success_debit_visa
    build(token: "tok_visa_debit")
  end

  def card_number(card_type)
    case card_type
    when :success
      "4242 4242 4242 4242"
    when :success_with_sca
      "4000 0025 0000 3155"
    when :success_indian_card_mandate
      "4000 0035 6000 0123"
    when :success_charge_decline
      "4000 0000 0000 0341"
    when :decline
      "4000 0000 0000 0002"
    else
      "4242 4242 4242 4242"
    end
  end
end
