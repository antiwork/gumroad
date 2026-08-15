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

  # Creation-time gate. Unresolved DNS is false here (don't persist a URL we cannot prove public);
  # delivery uses #post_url_delivery_status so a transient empty lookup can retry instead of drop.
  def self.valid_post_url?(post_url)
    post_url_delivery_status(post_url) == :ok
  end

  # :ok / :reserved / :unresolved / :invalid. Delivery must not treat :unresolved like :reserved —
  # empty Resolv results are usually a blip, not a private hop.
  def self.post_url_delivery_status(post_url)
    uri = URI.parse(post_url)
    return :invalid unless uri.kind_of?(URI::HTTP) && uri.hostname.present?

    # uri.hostname (not uri.host) strips IPv6 brackets so Resolv/IPAddr get "::1", not "[::1]".
    ip_addresses = resolve_addresses(uri.hostname)
    return :unresolved if ip_addresses.empty?
    return :reserved if ip_addresses.any? { |ip| reserved_ip_address?(ip) }

    :ok
  rescue URI::InvalidURIError, IPAddr::Error
    :invalid
  rescue Resolv::ResolvError
    :unresolved
  end

  # Extracted as its own method (rather than inlined) so specs can stub DNS resolution instead of
  # depending on real external hostnames resolving during a test run.
  def self.resolve_addresses(hostname)
    Resolv.getaddresses(hostname).map { |ip| IPAddr.new(ip) }
  end

  def self.reserved_ip_address?(ip)
    blacklist = ip.ipv4? ? SsrfFilter::IPV4_BLACKLIST : SsrfFilter::IPV6_BLACKLIST
    blacklist.any? { |range| range.include?(ip) }
  end
  private_class_method :reserved_ip_address?

  private
    def assign_content_type_to_json_for_zapier
      self.content_type = Mime[:json] if URI.parse(post_url).host.ends_with?("zapier.com")
    end
end
