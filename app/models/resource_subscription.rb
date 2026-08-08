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

  # A literal-hostname blocklist (the old implementation here) only catches the exact strings an
  # attacker didn't bother varying — it misses other loopback forms, RFC1918/link-local ranges,
  # IPv6 private ranges, and any hostname that simply resolves to one of those. Resolve the
  # hostname and check the actual IPs against ssrf_filter's reserved-range list (the same gem and
  # blocklist the public media/thumbnail URL fetchers already trust) instead of pattern-matching
  # the URL string. Called again at delivery time in PostToPingEndpointsWorker, not just here at
  # creation, so a DNS record that starts pointing internal after the subscription is created
  # still gets caught before each send.
  def self.valid_post_url?(post_url)
    uri = URI.parse(post_url)
    return false unless uri.kind_of?(URI::HTTP) && uri.hostname.present?

    # uri.hostname (not uri.host) strips the brackets from a literal IPv6 host so it's a valid
    # Resolv/IPAddr input, e.g. "[::1]" -> "::1".
    resolves_to_public_address?(uri.hostname)
  rescue URI::InvalidURIError
    false
  end

  def self.resolves_to_public_address?(hostname)
    ip_addresses = resolve_addresses(hostname)
    return false if ip_addresses.empty?

    ip_addresses.none? { |ip| reserved_ip_address?(ip) }
  rescue IPAddr::Error
    false
  end
  private_class_method :resolves_to_public_address?

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
