# frozen_string_literal: true

class Settings::BillingController < Settings::BaseController
  before_action :authorize

  def show
    render inertia: "Settings/Billing/Show", props: settings_presenter.billing_props
  end

  def update
    billing_detail = current_seller.billing_detail || current_seller.build_billing_detail

    if billing_detail.update(billing_detail_params)
      redirect_to settings_billing_path, status: :see_other, notice: "Your billing details have been saved."
    else
      redirect_to settings_billing_path, alert: billing_detail.errors.full_messages.to_sentence
    end
  end

  private
    def billing_detail_params
      params.require(:billing_detail).permit(
        :full_name,
        :business_name,
        :business_id,
        :street_address,
        :city,
        :state,
        :zip_code,
        :country_code,
        :additional_notes,
        :auto_email_invoice_enabled
      )
    end

    def authorize
      super([:settings, :billing])
    end
end
