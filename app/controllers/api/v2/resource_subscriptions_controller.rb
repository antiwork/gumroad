# frozen_string_literal: true

class Api::V2::ResourceSubscriptionsController < Api::V2::BaseController
  before_action(only: [:index, :create, :destroy]) { doorkeeper_authorize! :view_sales }

  def index
    resource_name = params[:resource_name]

    if ResourceSubscription.valid_resource_name?(resource_name)
      success_with_object(:resource_subscriptions, current_resource_owner.resource_subscriptions.alive.where(resource_name: params[:resource_name]))
    else
      render_response(false, message: "Valid resource_name parameter required")
    end
  end

  def create
    resource_name = params[:resource_name]
    post_url = params[:post_url]

    return error_with_post_url(post_url) unless ResourceSubscription.valid_post_url?(post_url)

    if ResourceSubscription.valid_resource_name?(resource_name)
      resource_subscription = ResourceSubscription.create!(
        user: current_resource_owner,
        oauth_application: OauthApplication.find(doorkeeper_token.application.id),
        resource_name:,
        post_url:
      )
      success_with_resource_subscription(resource_subscription)
    else
      error_with_subscription_resource(resource_subscription)
    end
  end

  def destroy
    resource_subscription = ResourceSubscription.find_by_external_id(params[:id])

    if resource_subscription && doorkeeper_token.application_id == resource_subscription.oauth_application.id
      resource_subscription.mark_deleted!
      success_with_resource_subscription(nil)
    else
      error_with_object(:resource_subscription, nil)
    end
  end

  def error_with_subscription_resource(resource_name)
    render_response(false, message: "Unable to subscribe to '#{resource_name}'.")
  end

  def error_with_post_url(post_url)
    render_response(false, message: "Invalid post URL '#{post_url}'")
  end

  def success_with_resource_subscription(resource_subscription)
    success_with_object(:resource_subscription, resource_subscription)
  end
end
