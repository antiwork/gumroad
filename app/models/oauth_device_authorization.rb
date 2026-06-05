# frozen_string_literal: true

require "digest"

class OauthDeviceAuthorization < ApplicationRecord
  GRANT_TYPE = "urn:ietf:params:oauth:grant-type:device_code"
  DEVICE_REDIRECT_URI = GRANT_TYPE
  EXPIRES_IN = 10.minutes
  POLL_INTERVAL = 5.seconds
  SLOW_DOWN_INTERVAL = 10.seconds
  SLOW_DOWN_INCREMENT = 5.seconds
  MAX_CODE_GENERATION_ATTEMPTS = 3

  STATUS_PENDING = "pending"
  STATUS_APPROVED = "approved"
  STATUS_DENIED = "denied"
  STATUS_CONSUMED = "consumed"
  STATUSES = [STATUS_PENDING, STATUS_APPROVED, STATUS_DENIED, STATUS_CONSUMED].freeze
  EXPIRABLE_STATUSES = STATUSES

  POLL_AUTHORIZATION_PENDING = "authorization_pending"
  POLL_SLOW_DOWN = "slow_down"
  POLL_EXPIRED_TOKEN = "expired_token"
  POLL_ACCESS_DENIED = "access_denied"
  POLL_APPROVED = "approved"

  belongs_to :oauth_application, class_name: "OauthApplication"
  belongs_to :resource_owner, class_name: "User", optional: true
  belongs_to :access_token, class_name: "Doorkeeper::AccessToken", optional: true

  validates :device_code_digest, :user_code_digest, :scopes, :status, :expires_at, :poll_interval_seconds, presence: true
  validates :device_code_digest, :user_code_digest, uniqueness: true
  validates :status, inclusion: { in: STATUSES }

  scope :expired_for_cleanup, -> { where(status: EXPIRABLE_STATUSES).where("expires_at <= ?", Time.current) }

  def self.create_for!(oauth_application:, scopes:, ip_address:, user_agent:)
    attempts = 0

    begin
      attempts += 1
      device_code = generate_device_code
      user_code = generate_user_code

      device_authorization = create!(
        oauth_application:,
        scopes:,
        device_code_digest: digest(device_code),
        user_code_digest: digest(normalize_user_code(user_code)),
        expires_at: EXPIRES_IN.from_now,
        created_ip_address: ip_address,
        created_user_agent: user_agent
      )

      [device_authorization, device_code, user_code]
    rescue ActiveRecord::RecordNotUnique
      retry if attempts < MAX_CODE_GENERATION_ATTEMPTS
      raise
    end
  end

  def self.find_by_device_code(device_code)
    return if device_code.blank?

    find_by(device_code_digest: digest(device_code))
  end

  def self.find_by_user_code(user_code)
    normalized_user_code = normalize_user_code(user_code)
    return if normalized_user_code.blank?

    find_by(user_code_digest: digest(normalized_user_code))
  end

  def self.digest(value)
    Digest::SHA256.hexdigest(value.to_s)
  end

  def self.normalize_user_code(user_code)
    user_code.to_s.upcase.gsub(/[^A-Z0-9]/, "")
  end

  def self.format_user_code(user_code)
    normalized_user_code = normalize_user_code(user_code)
    return "" if normalized_user_code.blank?
    return "GRD-#{normalized_user_code.delete_prefix("GRD").scan(/.{1,4}/).join("-")}" if normalized_user_code.start_with?("GRD")

    normalized_user_code.scan(/.{1,4}/).join("-")
  end

  def pending? = status == STATUS_PENDING
  def approved? = status == STATUS_APPROVED
  def denied? = status == STATUS_DENIED
  def consumed? = status == STATUS_CONSUMED
  def expired? = expires_at <= Time.current
  def approvable? = pending? && !expired?
  def scope_list = scopes.split

  def access_revoked_after_creation_for?(resource_owner)
    return false if resource_owner.blank?

    # oauth_access_tokens.revoked_at is second precision, so same-second revokes must invalidate the code.
    revocation_cutoff = created_at.change(usec: 0)

    oauth_application.access_tokens
      .where(resource_owner_id: resource_owner.id)
      .where("revoked_at >= ?", revocation_cutoff)
      .exists? &&
      !oauth_application.access_tokens
        .where(resource_owner_id: resource_owner.id, revoked_at: nil)
        .exists?
  end

  def approve!(resource_owner:, ip_address:, user_agent:)
    approved = false

    oauth_application.with_lock do
      with_lock do
        if approvable?
          if access_revoked_after_creation_for?(resource_owner)
            mark_denied!(resource_owner:, ip_address:, user_agent:)
          else
            update!(
              resource_owner:,
              status: STATUS_APPROVED,
              approved_at: Time.current,
              approved_ip_address: ip_address,
              approved_user_agent: user_agent
            )
            approved = true
          end
        end
      end
    end

    approved
  end

  def deny!(resource_owner:, ip_address:, user_agent:)
    denied = false

    oauth_application.with_lock do
      with_lock do
        if approvable?
          mark_denied!(resource_owner:, ip_address:, user_agent:)
          denied = true
        end
      end
    end

    denied
  end

  def poll!(oauth_application:, ip_address:, user_agent:)
    result = nil

    oauth_application.with_lock do
      with_lock do
        result = if oauth_application != self.oauth_application || consumed?
          [POLL_EXPIRED_TOKEN, nil]
        elsif denied?
          [POLL_ACCESS_DENIED, nil]
        elsif expired?
          [POLL_EXPIRED_TOKEN, nil]
        elsif pending?
          too_recent = polled_too_recently?
          next_poll_interval_seconds = too_recent ? poll_interval_seconds + SLOW_DOWN_INCREMENT.to_i : poll_interval_seconds
          update_poll_metadata!(ip_address:, user_agent:, poll_interval_seconds: next_poll_interval_seconds)
          too_recent ? [POLL_SLOW_DOWN, next_poll_interval_seconds] : [POLL_AUTHORIZATION_PENDING, nil]
        else
          if access_revoked_after_creation_for?(resource_owner)
            mark_denied!(resource_owner:, ip_address:, user_agent:)
            [POLL_ACCESS_DENIED, nil]
          else
            update_poll_metadata!(ip_address:, user_agent:)
            access_token = issue_access_token!
            update!(status: STATUS_CONSUMED, consumed_at: Time.current, access_token:)
            [POLL_APPROVED, access_token]
          end
        end
      end
    end

    result
  rescue ActiveRecord::RecordNotFound
    [POLL_EXPIRED_TOKEN, nil]
  end

  def self.generate_device_code
    SecureRandom.urlsafe_base64(32)
  end

  def self.generate_user_code
    "GRD-#{SecureRandom.alphanumeric(8).upcase.scan(/.{1,4}/).join("-")}"
  end
  private_class_method :generate_device_code, :generate_user_code

  private
    def update_poll_metadata!(ip_address:, user_agent:, poll_interval_seconds: self.poll_interval_seconds)
      update!(
        last_polled_at: Time.current,
        last_poll_ip_address: ip_address,
        last_poll_user_agent: user_agent,
        poll_count: poll_count + 1,
        poll_interval_seconds:
      )
    end

    def polled_too_recently?
      last_polled_at.present? && last_polled_at > poll_interval_seconds.seconds.ago
    end

    def mark_denied!(resource_owner:, ip_address:, user_agent:)
      update!(
        resource_owner:,
        status: STATUS_DENIED,
        denied_at: Time.current,
        denied_ip_address: ip_address,
        denied_user_agent: user_agent
      )
    end

    def issue_access_token!
      ensure_access_grant_exists!

      Doorkeeper.config.access_token_model.create_for(
        application: oauth_application,
        resource_owner: resource_owner_id,
        scopes:,
        expires_in: Doorkeeper.config.access_token_expires_in,
        use_refresh_token: Doorkeeper.config.refresh_token_enabled?
      )
    end

    def ensure_access_grant_exists!
      oauth_application.access_grants.where(
        resource_owner_id:,
        scopes:,
        redirect_uri: DEVICE_REDIRECT_URI
      ).first_or_create! { |access_grant| access_grant.expires_in = 60.years }
    end
end
