# frozen_string_literal: true

class Admin::MerchantAccountsController < Admin::BaseController
  def show
    @merchant_account = MerchantAccount.find_by(id: params[:id]) || MerchantAccount.find_by(charge_processor_merchant_id: params[:id]) || e404
    @title = "Merchant Account #{@merchant_account.id}"
    load_live_attributes
  end

  private
    def load_live_attributes
      return unless @merchant_account.charge_processor_merchant_id.present?

      if @merchant_account.stripe_charge_processor?
        stripe_account = Stripe::Account.retrieve(@merchant_account.charge_processor_merchant_id)
        @live_attributes = {
          "Charges enabled" => stripe_account.charges_enabled,
          "Payout enabled" => stripe_account.payouts_enabled,
          "Disabled reason" => stripe_account.requirements.disabled_reason,
          "Fields needed" => stripe_account.requirements.as_json
        }
      elsif @merchant_account.paypal_charge_processor?
        paypal_account_details = @merchant_account.paypal_account_details
        if paypal_account_details.present?
          @live_attributes = {
            "Email" => paypal_account_details["primary_email"]
          }
        end
      end
    end
end
