# frozen_string_literal: true

require "ipaddr"
require "resolv"

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

  BLOCKED_POST_URL_IP_RANGES = [
    "0.0.0.0/8",
    "10.0.0.0/8",
    "100.64.0.0/10",
    "127.0.0.0/8",
    "169.254.0.0/16",
    "172.16.0.0/12",
    "192.0.0.0/24",
    "192.0.2.0/24",
    "192.168.0.0/16",
    "198.18.0.0/15",
    "198.51.100.0/24",
    "203.0.113.0/24",
    "224.0.0.0/4",
    "240.0.0.0/4",
    "255.255.255.255/32",
    "::/128",
    "::1/128",
    "::ffff:0:0/96",
    "64:ff9b:1::/48",
    "100::/64",
    "2001:2::/48",
    "2001:db8::/32",
    "fc00::/7",
    "fe80::/10",
    "ff00::/8"
  ].map { IPAddr.new(_1) }.freeze

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

  def self.valid_post_url?(post_url, require_resolvable: false)
    uri = URI.parse(post_url)
    return false unless uri.kind_of?(URI::HTTP)
    return false if uri.host.blank?
    return false if uri.host.downcase == "localhost"

    host_ip = begin
      IPAddr.new(uri.host)
    rescue IPAddr::InvalidAddressError
      nil
    end
    return false if host_ip.present? && blocked_post_url_ip?(host_ip)
    return false if host_ip.nil? && uri.host.match?(/\A[\dA-Fa-f:.]+\z/)

    resolved_ips = Resolv.getaddresses(uri.host).map { IPAddr.new(_1) }
    return !require_resolvable if resolved_ips.empty?

    resolved_ips.none? { blocked_post_url_ip?(_1) }
  rescue URI::InvalidURIError, IPAddr::InvalidAddressError, Resolv::ResolvError, TypeError
    false
  end

  def self.blocked_post_url_ip?(ip)
    BLOCKED_POST_URL_IP_RANGES.any? { _1.include?(ip) }
  end

  private
    def assign_content_type_to_json_for_zapier
      self.content_type = Mime[:json] if URI.parse(post_url).host.ends_with?("zapier.com")
    end
end
