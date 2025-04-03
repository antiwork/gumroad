# frozen_string_literal: true

FactoryBot.define do
  factory :chargeable, class: Chargeable do
    skip_create # Chargeable is not an ActiveRecord object

    transient do
      card { StripePaymentMethodHelper.success }
      expiry_date { card[:expiry_date] }
      cvc { card[:cvc] }
      with_zip_code { nil }
      cc_zipcode do
        card = self.card
        # if with_zip_code has been set, take the action of adding or removing zip code from the card params in use
        # but if with_zip_code has not been set (nil) do nothing to the card params
        case with_zip_code
        when true
          card = card.with_zip_code
        when false
          card = card.without(:cc_zip_code)
        end
        card[:cc_zipcode]
      end
      product_permalink { "xx" }
    end

    initialize_with do
      self.card[:expiry_date] = expiry_date
      self.card[:cvc] = cvc
      self.card[:cc_zipcode] = cc_zipcode
      Chargeable.new([
                       StripeChargeablePaymentMethod.new(self.card.to_stripejs_payment_method_id, zip_code: self.card[:cc_zipcode], product_permalink:)
                     ])
    end

    factory :chargeable_zip_check_unsupported do
      transient do
        card { StripePaymentMethodHelper.success_zip_check_unsupported }
      end
    end

    factory :chargeable_zip_check_fails do
      transient do
        card { StripePaymentMethodHelper.success_zip_check_fails }
      end
    end

    factory :chargeable_decline do
      transient do
        card { StripePaymentMethodHelper.decline }
      end
    end

    factory :chargeable_success_charge_decline do
      transient do
        card { StripePaymentMethodHelper.success_charge_decline }
      end
    end

    factory :chargeable_success_charge_disputed do
      transient do
        card { StripePaymentMethodHelper.success_charge_disputed }
      end
    end

    factory :chargeable_decline_cvc_check_fails do
      transient do
        card { StripePaymentMethodHelper.decline_cvc_check_fails }
      end
    end
  end

  factory :cc_token_chargeable, class: Chargeable do
    skip_create # Chargeable is not an ActiveRecord object

    transient do
      card { CardParamsSpecHelper.success }
      expiry_date { card[:expiry_date] }
      cvc { card[:cvc] }
      with_zip_code { nil }
      cc_zipcode do
        card = self.card
        # if with_zip_code has been set, take the action of adding or removing zip code from the card params in use
        # but if with_zip_code has not been set (nil) do nothing to the card params
        case with_zip_code
        when true
          card = card.with_zip_code
        when false
          card = card.without(:cc_zip_code)
        end
        card[:cc_zipcode]
      end
    end

    initialize_with do
      self.card[:expiry_date] = expiry_date
      self.card[:cvc] = cvc
      self.card[:cc_zipcode] = cc_zipcode
      Chargeable.new([
                       StripeChargeableToken.new(self.card.to_stripejs_token, self.card[:cc_zipcode], product_permalink: "xx")
                     ])
    end
  end

  factory :paypal_chargeable, class: Chargeable do
    skip_create

    initialize_with do
      Chargeable.new([
                       BraintreeChargeableNonce.new(Braintree::Test::Nonce::PayPalFuturePayment, nil)
                     ])
    end
  end

  factory :native_paypal_chargeable, class: Chargeable do
    skip_create

    initialize_with do
      Chargeable.new([
                       PaypalChargeable.new("B-8AM85704X2276171X", "paypal_paypal-gr-integspecs@gumroad.com", "US")
                     ])
    end
  end

  factory :paypal_approved_order_chargeable, class: Chargeable do
    skip_create

    initialize_with do
      Chargeable.new([
                       PaypalApprovedOrderChargeable.new("9XX680320L106570A", "paypal_paypal-gr-integspecs@gumroad.com", "US")
                     ])
    end
  end
end
