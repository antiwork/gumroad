# frozen_string_literal: true

class Api::Mobile::SubscriptionsController < Api::Mobile::BaseController
  before_action :fetch_subscription_by_external_id, only: :subscription_attributes

  def subscription_attributes
    render json: { success: true, subscription: @subscription.subscription_mobile_json_data }
  end
end
