# frozen_string_literal: true

require "ipaddr"

class CustomDomain < ApplicationRecord
  WWW_PREFIX = "www"
  MAX_FAILED_VERIFICATION_ATTEMPTS_COUNT = 3

  include Deletable

  stripped_fields :domain, transform: -> { _1.downcase }

  belongs_to :user, optional: true
  belongs_to :product, class_name: "Link", optional: true

  validate :user_or_product_present
  validate :validate_domain_uniqueness
  validate :validate_domain_format
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
    if domain.blank? || !domain.match?(/\A[a-zA-Z0-9\-.]+[^.]\z/) || !PublicSuffix.valid?(domain) || ip_address?(domain)
      errors.add(:base, "#{domain} is not a valid domain name.")
    end
  end

  def validate_domain_is_allowed
    forbidden_suffixes = [DOMAIN, ROOT_DOMAIN, SHORT_DOMAIN, DISCOVER_DOMAIN, API_DOMAIN, INTERNAL_GUMROAD_DOMAIN].freeze

    forbidden_suffixes.each do |suffix|
      if domain == suffix || domain.to_s.ends_with?(".#{suffix}")
        return errors.add(:base, "#{domain} is not a valid domain name.")
      end
    end
  end

  def verify(allow_incrementing_failed_verification_attempts_count: true)
    self.allow_incrementing_failed_verification_attempts_count = allow_incrementing_failed_verification_attempts_count

    has_valid_configuration = CustomDomainVerificationService.new(domain:).process

    if has_valid_configuration
      mark_verified if unverified?
    else
      verified? ? mark_unverified : increment_failed_verification_attempts_count_and_notify_creator
    end
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

  def generate_ssl_certificate
    GenerateSslCertificate.perform_in(2.seconds, id)
  end

  def has_valid_certificate?(renew_certificate_in)
    ssl_certificate_issued_at.present? && ssl_certificate_issued_at > renew_certificate_in.ago
  end

  def exceeding_max_failed_verification_attempts?
    failed_verification_attempts_count >= MAX_FAILED_VERIFICATION_ATTEMPTS_COUNT
  end

  def active?
    verified? && has_valid_certificate?(1.week)
  end

  private
    attr_accessor :allow_incrementing_failed_verification_attempts_count

    def reset_ssl_certificate_issued_at
      self.ssl_certificate_issued_at = nil
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
end
