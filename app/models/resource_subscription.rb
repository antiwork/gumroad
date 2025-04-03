# frozen_string_literal: true

class ResourceSubscription < ApplicationRecord
  include ExternalId
  include Deletable

  SALE_RESOURCE_NAME = "sale"
  CANCELLED_RESOURCE_NAME = "cancellation"
  SUBSCRIPTION_ENDED_RESOURCE_NAME = "subscription_ended"
  SUBSCRIPTION_RESTARTED_RESOURCE_NAME = "subscription_restarted"
  SUBSCRIPTION_UPDATED_RESOURCE_NAME = "subscription_updated"
  REFUNDED_RESOURCE_NAME = "refund"
  DISPUTE_RESOURCE_NAME = "dispute"
  DISPUTE_WON_RESOURCE_NAME = "dispute_won"

  VALID_RESOURCE_NAMES = [SALE_RESOURCE_NAME,
                          CANCELLED_RESOURCE_NAME,
                          SUBSCRIPTION_ENDED_RESOURCE_NAME,
                          SUBSCRIPTION_RESTARTED_RESOURCE_NAME,
                          SUBSCRIPTION_UPDATED_RESOURCE_NAME,
                          REFUNDED_RESOURCE_NAME,
                          DISPUTE_RESOURCE_NAME,
                          DISPUTE_WON_RESOURCE_NAME].freeze

  INVALID_POST_URL_HOSTS = %w(127.0.0.1 localhost 0.0.0.0)

  belongs_to :user, optional: true
  belongs_to :oauth_application, optional: true

  validates_presence_of :user, :oauth_application, :resource_name

  before_create :assign_content_type_to_json_for_zapier

  def as_json(_options = {})
    {
      "id" => external_id,
      "resource_name" => resource_name,
      "post_url" => post_url
    }
  end

  def self.valid_resource_name?(resource_name)
    VALID_RESOURCE_NAMES.include?(resource_name)
  end

  def self.valid_post_url?(post_url)
    uri = URI.parse(post_url)
    uri.kind_of?(URI::HTTP) && INVALID_POST_URL_HOSTS.exclude?(uri.host)
  rescue URI::InvalidURIError
    false
  end

  private
    def assign_content_type_to_json_for_zapier
      self.content_type = Mime[:json] if URI.parse(post_url).host.ends_with?("zapier.com")
    end
end
