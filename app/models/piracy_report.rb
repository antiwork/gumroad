# frozen_string_literal: true

class PiracyReport < ApplicationRecord
  MONTHLY_LIMIT = 5
  MIN_SUCCESSFUL_SALES = 1
  MAX_REASON_LENGTH = 280
  # The reported URL prints in the notice as written, so it gets a tighter bound than the column.
  MAX_REPORTED_URL_LENGTH = 500
  EXTERNAL_ID_LENGTH = 21
  EXTERNAL_ID_ALPHABET = "_-0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"

  HOSTED_ON_GUMROAD_ERROR = "Pages hosted on Gumroad are reported through the terms of service process"
  SOURCES = %w[dashboard support].freeze
  # Judgment checks only the agent can make. What Rails can prove is in PiracyReports::Eligibility.
  SCREENING_CHECKS = %w[
    page_offers_work
    not_other_authorized_use
    not_licensee_or_related_party
  ].freeze

  belongs_to :seller, class_name: "User"
  belongs_to :product, class_name: "Link"
  before_validation :generate_external_id, on: :create
  before_validation :set_normalized_url_digest

  validates :external_id, :state, :url, :normalized_url_digest, presence: true
  validates :url, length: { maximum: MAX_REPORTED_URL_LENGTH }
  validates :ticket_url, length: { maximum: 1024 }
  validates :recipient_email, length: { maximum: 254 }
  validates :source, inclusion: { in: SOURCES }
  validate :url_is_http_url

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

    event :sign do
      transition awaiting_signature: :signed
    end
  end

  # The seller signs the text frozen on the row, so the signature and the digest travel together.
  # The lock makes the transition and the signature one step against a second submit.
  def record_signature!(name)
    with_lock do
      errors.add(:base, "This report is not ready to sign") unless awaiting_signature?
      errors.add(:base, "The notice has not been generated yet") if notice_text.blank?
      errors.add(:signed_by_name, "must be your full legal name") if name.to_s.strip.blank?
      next false if errors.any?

      assign_attributes(signed_by_name: name.to_s.squish, signed_at: Time.current)
      sign
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
end
