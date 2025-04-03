# frozen_string_literal: true

class OauthApplication < Doorkeeper::Application
  include ExternalId
  include Deletable
  include CdnUrlHelper

  has_many :resource_subscriptions, dependent: :destroy
  has_many :affiliate_credits
  has_many :links, foreign_key: :affiliate_application_id

  belongs_to :owner, class_name: "User", optional: true

  before_validation :set_default_scopes, on: :create

  validates :scopes, presence: true
  validate :affiliate_basis_points_must_fall_in_an_acceptable_range
  validate :validate_file

  ALLOW_CONTENT_TYPES = /jpeg|png|jpg/i
  MOBILE_API_OAUTH_APPLICATION_UID = GlobalConfig.get("MOBILE_API_OAUTH_APPLICATION_UID")

  def validate_file
    return unless file.attached?

    if !file.image? || !file.content_type.match?(ALLOW_CONTENT_TYPES)
      errors.add(:base, "Invalid image type for icon, please try again.")
    end
  end

  def mark_deleted!
    transaction do
      access_grants.where(revoked_at: nil).update_all(revoked_at: Time.current)
      access_tokens.where(revoked_at: nil).update_all(revoked_at: Time.current)
      resource_subscriptions.alive.each(&:mark_deleted!)
      update!(deleted_at: Time.current)
    end
  end

  def affiliate_basis_points_must_fall_in_an_acceptable_range
    return if affiliate_basis_points.nil?
    return if affiliate_basis_points >= 0 && affiliate_basis_points <= 7000

    errors.add(:base, "Affiliate commission must be between 0% and 70%")
  end

  has_one_attached :file

  def affiliate_basis_points=(affiliate_basis_points)
    return unless self.affiliate_basis_points.nil?

    self[:affiliate_basis_points] = affiliate_basis_points
  end

  def affiliate_percent
    return nil if affiliate_basis_points.nil?

    affiliate_basis_points / 100.0
  end

  # Returns an existing active access token or creates one if none exist
  def get_or_generate_access_token
    ensure_access_grant_exists
    access_tokens.where(resource_owner_id: owner.id,
                        revoked_at: nil,
                        scopes: Doorkeeper.configuration.public_scopes.join(" ")).first_or_create!
  end

  def revoke_access_for(user)
    Doorkeeper::AccessToken.revoke_all_for(id, user)
    resource_subscriptions.where(user:).alive.each(&:mark_deleted!)
  end

  def icon_url
    return unless file.attached?

    cdn_url_for(file.url)
  end

  private
    def ensure_access_grant_exists
      access_grants.where(resource_owner_id: owner.id,
                          scopes: Doorkeeper.configuration.public_scopes.join(" "),
                          redirect_uri:).first_or_create! { |access_grant| access_grant.expires_in = 60.years }
    end

    def set_default_scopes
      self.scopes = Doorkeeper.configuration.public_scopes.join(" ") unless self.scopes.present?
    end
end
