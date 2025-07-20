# frozen_string_literal: true

class PostToPingEndpointsWorker
  include Sidekiq::Job
  sidekiq_options retry: 20, queue: :critical

  def perform(purchase_id, url_parameters, resource_name = ResourceSubscription::SALE_RESOURCE_NAME, subscription_id = nil, additional_params = {})
    ActiveRecord::Base.connection.stick_to_primary!

    if subscription_id.present?
      subscription = Subscription.find(subscription_id)
      return if resource_name == ResourceSubscription::SUBSCRIPTION_ENDED_RESOURCE_NAME && subscription.deactivated_at.blank?
      return if resource_name == ResourceSubscription::SUBSCRIPTION_RESTARTED_RESOURCE_NAME && subscription.termination_date.present?
      user = subscription.link.user
      ping_params = subscription.payload_for_ping_notification(resource_name:, additional_params:)
    else
      purchase = Purchase.find(purchase_id)
      user = purchase.seller
      ping_params = purchase.payload_for_ping_notification(url_parameters:, resource_name:)
    end

    post_urls = user.urls_for_ping_notification(resource_name)
    return if post_urls.empty?

    post_urls.each do |post_url, content_type|
      next unless ResourceSubscription.valid_post_url?(post_url)
      PostToIndividualPingEndpointWorker.perform_async(post_url, ping_params.deep_stringify_keys, content_type, user.id)
    end
  end
end
