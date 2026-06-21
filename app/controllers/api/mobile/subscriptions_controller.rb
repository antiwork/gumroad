# frozen_string_literal: true

class Api::Mobile::SubscriptionsController < Api::Mobile::BaseController
  before_action -> { doorkeeper_authorize! :mobile_api }, only: :cancel
  before_action :fetch_subscription_by_external_id, only: :subscription_attributes

  def subscription_attributes
    render json: { success: true, subscription: @subscription.subscription_mobile_json_data }
  end

  def cancel
    subscription = Subscription.find_by_external_id(params[:id])
    if subscription.nil? || subscription.seller_id != current_resource_owner.id
      return fetch_error("Could not find subscription")
    end

    subscription.cancel!(by_seller: true)
    render json: { success: true }
  end
end
