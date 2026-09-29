# frozen_string_literal: true

class PiracyReport < ApplicationRecord
  MONTHLY_LIMIT = 5
  MIN_SUCCESSFUL_SALES = 1
  MAX_REASON_LENGTH = 280
  MAX_URL_LENGTH = 2048
  # The reported URL prints in the notice as written, so it gets a tighter bound than the column.
  MAX_REPORTED_URL_LENGTH = 500
  EXTERNAL_ID_LENGTH = 21
  EXTERNAL_ID_ALPHABET = "_-0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"

  # The only third-party page a recipient address may be sourced from: any other page could be
  # one a pirate wrote.
  COPYRIGHT_DIRECTORY_HOST = "dmca.copyright.gov"
  HOSTED_ON_GUMROAD_ERROR = "Pages hosted on Gumroad are reported through the terms of service process"
  SOURCES = %w[dashboard support].freeze
  RECIPIENT_KINDS = %w[site host].freeze
  # Judgment checks only the agent can make. What Rails can prove is in PiracyReports::Eligibility.
  SCREENING_CHECKS = %w[
    page_offers_work
    not_other_authorized_use
    not_licensee_or_related_party
    recipient_found
  ].freeze

  belongs_to :seller, class_name: "User"
  belongs_to :product, class_name: "Link"
  has_many :events, class_name: "PiracyReportEvent", dependent: nil

  attr_accessor :creation_actor

  before_validation :generate_external_id, on: :create
  before_validation :set_normalized_url_digest

  validates :external_id, :state, :url, :normalized_url_digest, presence: true
  validates :url, length: { maximum: MAX_REPORTED_URL_LENGTH }
  validates :recipient_source_url, length: { maximum: MAX_URL_LENGTH }
  validates :ticket_url, length: { maximum: 1024 }
  validates :recipient_email, length: { maximum: 254 }
  validates :source, inclusion: { in: SOURCES }
  validates :recipient_kind, inclusion: { in: RECIPIENT_KINDS }, allow_nil: true
  validate :url_is_http_url

  after_create :record_created_event

  state_machine :state, initial: :requested do
    event :start_screening do
      transition requested: :screening
    end

    event :pass_screening do
      transition screening: :awaiting_signature
    end

    event :fail_screening do
      transition screening: :declined
    end

    after_transition do |report, transition|
      report.record_event!(event: transition.event, from_state: transition.from, to_state: transition.to, actor: transition.args.first)
    end
  end

  def self.parse_http_url(value)
    uri = URI.parse(value.to_s.strip)
    # Credentials before the host let a URL print another domain first ("https://other.com@host/").
    uri if uri.is_a?(URI::HTTP) && uri.host.present? && uri.userinfo.blank?
  rescue URI::InvalidURIError
    nil
  end

  def self.normalized_host(host)
    host.to_s.downcase.chomp(".").delete_prefix("www.")
  end

  # A site's contact page is often on the apex domain while the file is on a CDN subdomain, so
  # sources compare by registrable domain. IP hosts match exactly: the suffix list pairs "1.1".
  def self.registrable_domain(host)
    host = normalized_host(host)
    return host if host.match?(/\A[\d.]+\z/) || host.include?(":")

    PublicSuffix.domain(host) || host
  end

  # Two spellings of the same page must collide on the unique index, so drop the scheme, "www.",
  # the fragment, a trailing slash and query order. A non-default port stays: it can be another server.
  def self.normalize_url(value)
    uri = parse_http_url(value)
    return if uri.nil?

    path = uri.path.presence || "/"
    path = path.chomp("/") if path.length > 1
    query = uri.query.to_s.split("&").sort.join("&").presence
    port = ":#{uri.port}" unless uri.port == uri.default_port
    "#{normalized_host(uri.host)}#{port}#{path}#{"?#{query}" if query}"
  end

  def self.gumroad_domains
    [ROOT_DOMAIN, SHORT_DOMAIN, DISCOVER_DOMAIN, API_DOMAIN, DEFAULT_EMAIL_DOMAIN].compact.map { _1.to_s.split(":").first.downcase }.uniq
  end

  def self.gumroad_host?(host)
    host = normalized_host(host)
    gumroad_domains.any? { |domain| host == domain || host.end_with?(".#{domain}") }
  end

  # A seller's custom domain is hosted by Gumroad too, so it goes through the terms of service.
  def self.gumroad_hosted?(host)
    normalized = normalized_host(host)
    gumroad_host?(normalized) || CustomDomain.alive.exists?(domain: [normalized, "www.#{normalized}"])
  end

  def self.created_this_month_count(seller)
    where(seller_id: seller.id, created_at: Time.current.beginning_of_month..).count
  end

  def url_host
    self.class.normalized_host(self.class.parse_http_url(url)&.host)
  end

  def record_event!(event:, from_state: nil, to_state: nil, actor: nil, data: nil)
    events.create!(
      event: event.to_s,
      from_state: from_state&.to_s,
      to_state: to_state&.to_s,
      actor_type: actor_type_for(actor),
      actor_id: actor&.id,
      data:
    )
  end

  private
    def generate_external_id
      return if external_id.present?

      loop do
        self.external_id = Array.new(EXTERNAL_ID_LENGTH) { EXTERNAL_ID_ALPHABET[SecureRandom.random_number(EXTERNAL_ID_ALPHABET.length)] }.join
        break unless self.class.exists?(external_id:)
      end
    end

    def set_normalized_url_digest
      normalized = self.class.normalize_url(url)
      self.normalized_url_digest = Digest::SHA256.hexdigest(normalized) if normalized
    end

    def url_is_http_url
      if self.class.parse_http_url(url).nil?
        errors.add(:url, "must be an http or https URL")
      elsif embeds_another_url?
        errors.add(:url, "must not contain another URL")
      end
    end

    # A second URL inside the path or query would print in the notice as a second target.
    def embeds_another_url?
      url.strip.sub(%r{\Ahttps?://[^/?#]*}i, "").match?(/https?(:|%3a)/i)
    end

    def record_created_event
      record_event!(event: "created", to_state: state, actor: creation_actor, data: { source: })
    end

    def actor_type_for(actor)
      return "system" if actor.nil?

      actor.id == seller_id ? "seller" : "admin_actor"
    end
end
