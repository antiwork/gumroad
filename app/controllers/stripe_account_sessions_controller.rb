# frozen_string_literal: true

class StripeAccountSessionsController < Sellers::BaseController
  before_action :authorize

  def create
    connected_account_id = current_seller.stripe_account&.charge_processor_merchant_id
    if connected_account_id.blank?
      return render json: { success: false, error_message: "User does not have a Stripe account" }
    end

    begin
      session = Stripe::AccountSession.create(
        {
          account: connected_account_id,
          components: {
            notification_banner: {
              enabled: true,
              features: { external_account_collection: true }
            }
          }
        }
      )

      render json: { success: true, client_secret: session.client_secret }
    rescue Stripe::InvalidRequestError => e
      if e.message.include?("No such account")
        render json: { success: false, error_message: "Your Stripe account is no longer active. Please reconnect your Stripe account." }
      else
        ErrorNotifier.notify("Failed to create stripe account session for user #{current_seller.id}: #{e.message}")
        render json: { success: false, error_message: "Failed to create stripe account session" }
      end
    rescue => e
      ErrorNotifier.notify("Failed to create stripe account session for user #{current_seller.id}: #{e.message}")
      render json: { success: false, error_message: "Failed to create stripe account session" }
    end
  end

  private
    def authorize
      super([:stripe_account_sessions, current_seller])
    end
end
