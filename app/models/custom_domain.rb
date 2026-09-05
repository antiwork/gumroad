# frozen_string_literal: true

require "ipaddr"

class CustomDomain < ApplicationRecord
  WWW_PREFIX = "www"
  MAX_FAILED_VERIFICATION_ATTEMPTS_COUNT = 3
  ROUTABILITY_REFRESH_INTERVAL = 6.hours
  # How long a Let's Encrypt certificate is actually good for. Renewal starts earlier
  # (renew_in in config/ssl_certificates.yml.erb, 75 days) so that issuance — an async
  # Sidekiq job that can be rate-limited for days — has room to finish while the current
  # certificate still works. Judging active? against renew_in instead would drop the
  # seller back to their *.gumroad.com subdomain the moment renewal became due, throwing
  # that buffer away; a spec pins renew_in below this.
  CERTIFICATE_LIFETIME = 90.days

  include Deletable

  stripped_fields :domain, transform: -> { _1.downcase }

  belongs_to :user, optional: true
  belongs_to :product, class_name: "Link", optional: true

  validate :user_or_product_present
  validate :validate_domain_uniqueness
  # Skipped for soft-deleted records: rows saved before this validation
  # existed may carry domains that fail it, and deleting such a record
  # (mark_deleted! runs save!) must not raise — deletion is exactly how a
  # seller or admin removes a broken domain.
  validate :validate_domain_format, unless: :deleted?
  validate :validate_domain_is_allowed

  before_save :reset_ssl_certificate_issued_at, if: :domain_changed?
  after_commit :generate_ssl_certificate, if: ->(custom_domain) { custom_domain.previous_changes[:domain].present? }

  scope :certificate_absent_or_older_than, -> (duration) { where("ssl_certificate_issued_at IS NULL OR ssl_certificate_issued_at < ?", duration.ago) }
  scope :certificates_younger_than, -> (duration) { where("ssl_certificate_issued_at > ?", duration.ago) }
  scope :verified, -> { with_state(:verified) }
  scope :unverified, -> { with_state(:unverified) }

  state_machine :state, initial: :unverified do
    after_transition unverified: :verified, do: ->(record) { record.failed_verification_attempts_count = 0 }
    after_transition verified: :unverified,  do: :increment_failed_verification_attempts_count_and_notify_creator

    event :mark_verified do
      transition unverified: :verified
    end

    event :mark_unverified do
      transition verified: :unverified
    end
  end

  def validate_domain_uniqueness
    custom_domain = CustomDomain.find_by_host(domain)
    return if custom_domain.nil? || custom_domain == self

    errors.add(:base, "The custom domain is already in use.")
  end

  def validate_domain_format
    # LetsEncrypt allows only valid hostnames when generating SSL certificates
    # Ref: https://github.com/letsencrypt/boulder/pull/1437#issuecomment-533533967
    errors.add(:base, "#{domain} is not a valid domain name.") unless certificate_domain_valid?
  end

  def validate_domain_is_allowed
    errors.add(:base, "#{domain} is not a valid domain name.") unless certificate_domain_allowed?
  end

  def verify(allow_incrementing_failed_verification_attempts_count: true, verification_service: CustomDomainVerificationService.new(domain:))
    self.allow_incrementing_failed_verification_attempts_count = allow_incrementing_failed_verification_attempts_count

    has_valid_configuration = verification_service.process

    if has_valid_configuration
      mark_verified if unverified?
    else
      verified? ? mark_unverified : increment_failed_verification_attempts_count_and_notify_creator
    end
  end

  def strictly_routable?
    return false unless active?

    RefreshCustomDomainRoutabilityWorker.perform_async(id) if routability_refresh_due?
    routable?
  end

  def set_routability!(routable, checked_domain: domain, observed_at: Time.current)
    persist_routability!(routable:, checked_domain:, observed_at:, clear_certificate: false)
  end

  def activate_with_routability!(routable, checked_domain: domain, observed_at: Time.current)
    activated = self.class.transaction do
      locked_domain = self.class.alive.lock.find_by(id:, domain: checked_domain)
      next false unless locked_domain

      locked_domain.ssl_certificate_issued_at = Time.current
      if locked_domain.routability_checked_at.nil? || locked_domain.routability_checked_at < observed_at
        locked_domain.routable = routable
        locked_domain.routability_checked_at = observed_at
      end
      locked_domain.save!
      true
    end

    reload if activated
    activated
  end

  def require_certificate_for_routability!(checked_domain: domain, observed_at: Time.current)
    persist_routability!(routable: false, checked_domain:, observed_at:, clear_certificate: true)
  end

  def routability_refresh_due?
    routability_checked_at.nil? || routability_checked_at < ROUTABILITY_REFRESH_INTERVAL.ago
  end

  def self.find_by_host(host)
    return unless PublicSuffix.valid?(host)

    parsed_host = PublicSuffix.parse(host)
    if parsed_host.trd.nil? || parsed_host.trd == WWW_PREFIX
      alive.find_by(domain: parsed_host.domain) || alive.find_by(domain: "#{WWW_PREFIX}.#{parsed_host.domain}")
    else
      alive.find_by(domain: host)
    end
  end

  def reset_ssl_certificate_issued_at!
    self.ssl_certificate_issued_at = nil
    self.save!
  end

  def set_ssl_certificate_issued_at!
    self.ssl_certificate_issued_at = Time.current
    self.save!
  end

  def generate_ssl_certificate(delay: 2.seconds, dedupe: false)
    if dedupe
      GenerateSslCertificate.set(GenerateSslCertificate::RENEWAL_LOCK_OPTIONS).perform_in(delay, id)
    else
      GenerateSslCertificate.perform_in(delay, id)
    end
  end

  # Cheap enqueue gate for SslCertificates::Renew: skips domains that cannot get
  # a certificate right now (names Let's Encrypt rejects outright, or a recent
  # failed order cached by the worker). The worker still runs the full checks.
  def certificate_orderable?
    certificate_domain_valid? &&
      certificate_domain_allowed? &&
      Rails.cache.read(domain_check_cache_key) != false
  end

  def has_valid_certificate?(renew_certificate_in)
    ssl_certificate_issued_at.present? && ssl_certificate_issued_at > renew_certificate_in.ago
  end

  def exceeding_max_failed_verification_attempts?
    failed_verification_attempts_count >= MAX_FAILED_VERIFICATION_ATTEMPTS_COUNT
  end

  def active?
    verified? && has_valid_certificate?(CERTIFICATE_LIFETIME)
  end

  private
    attr_accessor :allow_incrementing_failed_verification_attempts_count

    def reset_ssl_certificate_issued_at
      self.ssl_certificate_issued_at = nil
      self.routable = nil
      self.routability_checked_at = nil
    end

    def certificate_domain_valid?
      domain.present? &&
        domain.match?(/\A[a-zA-Z0-9\-.]+[^.]\z/) &&
        !malformed_label?(domain) &&
        PublicSuffix.valid?(domain) &&
        !ip_address?(domain)
    end

    def certificate_domain_allowed?
      forbidden_suffixes.none? { |suffix| domain == suffix || domain.to_s.ends_with?(".#{suffix}") }
    end

    def forbidden_suffixes
      [DOMAIN, ROOT_DOMAIN, SHORT_DOMAIN, DISCOVER_DOMAIN, API_DOMAIN, INTERNAL_GUMROAD_DOMAIN].freeze
    end

    # Matches SslCertificates::Generate#domain_check_cache_key so the negative
    # cache the worker writes on a failed order is honored here too.
    def domain_check_cache_key
      "domain_check_#{domain}"
    end

    def persist_routability!(routable:, checked_domain:, observed_at:, clear_certificate:)
      attributes = {
        routable:,
        routability_checked_at: observed_at,
        updated_at: Time.current,
      }
      attributes[:ssl_certificate_issued_at] = nil if clear_certificate

      matching_row = self.class.alive
        .where(id:, domain: checked_domain)
        .where("routability_checked_at IS NULL OR routability_checked_at < ?", observed_at)
      updated = matching_row.update_all(attributes)
      return false unless updated == 1

      reload
      true
    end

    def increment_failed_verification_attempts_count_and_notify_creator
      return unless allow_incrementing_failed_verification_attempts_count
      return if exceeding_max_failed_verification_attempts?

      increment(:failed_verification_attempts_count)
    end

    def user_or_product_present
      return if user.present? || product.present?
      errors.add(:base, "Requires an associated user or product.")
    end

    def ip_address?(domain)
      IPAddr.new(domain)
      true
    rescue IPAddr::InvalidAddressError
      false
    end

    # Hostnames like "example..com" contain an empty label (the part between
    # two consecutive dots), and ones like "-example.com" / "example-.com"
    # have a label starting or ending with a hyphen. PublicSuffix accepts
    # both, but they are not real hostnames — Let's Encrypt rejects them
    # (Acme::Client::Error::RejectedIdentifier), so a record carrying one
    # can never get an SSL certificate and would keep failing certificate
    # generation forever.
    def malformed_label?(domain)
      domain.split(".", -1).any? { |label| label.empty? || label.start_with?("-") || label.end_with?("-") }
    end
end
