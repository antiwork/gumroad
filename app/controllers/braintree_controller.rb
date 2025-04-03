# frozen_string_literal: true

# Braintree controller contains any stateless backend API calls we need to make for the frontend when tokenizing
# with Braintree. No other Braintree specific logic should ever live here, but instead can be found in the Charging
# module and in the BraintreeChargeProcessor implementation.
class BraintreeController < ApplicationController
  # Cache the client token for 10 minutes for each user (based on their guid). Disabled.
  # caches_action :client_token, expires_in: 10.minutes, cache_path: proc { cookies[:_gumroad_guid] }

  def client_token
    render json: {
      clientToken: Braintree::ClientToken.generate
    }
  rescue *BraintreeExceptions::UNAVAILABLE => e
    error_message = "BraintreeException: #{e.inspect}"
    Rails.logger.error error_message

    render json: {
      clientToken: nil
    }
  end

  def generate_transient_customer_token
    return render json: { transient_customer_store_key: nil } if params[:braintree_nonce].blank? || cookies[:_gumroad_guid].blank?

    begin
      raw_transient_customer_store_key = "#{cookies[:_gumroad_guid]}-#{SecureRandom.uuid}"
      transient_customer_store_key = ObfuscateIds.encrypt(raw_transient_customer_store_key)
      transient_customer_token = BraintreeChargeableTransientCustomer.tokenize_nonce_to_transient_customer(params[:braintree_nonce],
                                                                                                           transient_customer_store_key)
      transient_customer_store_key = transient_customer_token.try(:transient_customer_store_key)

      render json: { transient_customer_store_key: }
    rescue ChargeProcessorInvalidRequestError
      render json: {
        error: "Please check your card information, we couldn't verify it."
      }
    rescue ChargeProcessorUnavailableError
      render json: {
        error: "There is a temporary problem, please try again (your card was not charged)."
      }
    end
  end
end
