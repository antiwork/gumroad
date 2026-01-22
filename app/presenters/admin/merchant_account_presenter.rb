# frozen_string_literal: true

class Admin::MerchantAccountPresenter
  attr_reader :merchant_account

  def initialize(merchant_account:)
    @merchant_account = merchant_account
  end

  def props
    {
      charge_processor_id: merchant_account.charge_processor_id,
      charge_processor_merchant_id: merchant_account.charge_processor_merchant_id,
      created_at: merchant_account.created_at,
      external_id: merchant_account.external_id,
      user_external_id: merchant_account.user&.external_id,
      country: merchant_account.country,
      country_name:,
      currency: merchant_account.currency,
      holder_of_funds: merchant_account.holder_of_funds,
      stripe_account_url:,
      charge_processor_alive_at: merchant_account.charge_processor_alive_at,
      charge_processor_verified_at: merchant_account.charge_processor_verified_at,
      charge_processor_deleted_at: merchant_account.charge_processor_deleted_at,
      updated_at: merchant_account.updated_at,
      deleted_at: merchant_account.deleted_at,
      live_attributes: live_attributes || [],
    }
  end

  private
    def country_name
      merchant_account.country.presence && ISO3166::Country[merchant_account.country]&.common_name
    end

    def stripe_account_url
      return unless merchant_account.charge_processor_merchant_id?
      return unless merchant_account.stripe_charge_processor?

      StripeUrl.connected_account_url(merchant_account.charge_processor_merchant_id)
    end

    def live_attributes
      return unless merchant_account.charge_processor_merchant_id.present?

      if merchant_account.stripe_charge_processor?
        stripe_account = Stripe::Account.retrieve(merchant_account.charge_processor_merchant_id)
        [
          { label: "Charges enabled", value: stripe_account.charges_enabled },
          { label: "Payout enabled", value: stripe_account.payouts_enabled },
          { label: "Disabled reason", value: stripe_account.requirements.disabled_reason },
          { label: "Fields needed", value: stripe_account.requirements.as_json }
        ]
      elsif merchant_account.paypal_charge_processor?
        paypal_account_details = merchant_account.paypal_account_details
        if paypal_account_details.present?
          [
            { label: "Email", value: paypal_account_details["primary_email"] }
          ]
        end
      end
    end
end
