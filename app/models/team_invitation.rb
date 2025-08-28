# frozen_string_literal: true

class TeamInvitation < ApplicationRecord
  include ExternalId
  include TimestampStateFields

  has_paper_trail

  ACTIVE_INTERVAL_IN_DAYS = 7

  ROLES = TeamMembership::ROLES
    .excluding(TeamMembership::ROLE_OWNER)

  ROLES.each do |role|
    scope "role_#{role}", -> { where(role:) }
    define_method("role_#{role}?") do
      attributes["role"] == role
    end
  end

  stripped_fields :email, transform: -> { _1.downcase }

  timestamp_state_fields :accepted, :deleted

  belongs_to :seller, class_name: "User", foreign_key: :seller_id

  validates :email, email_format: true
  with_options if: :not_deleted? do
    validates_uniqueness_of :email, scope: %i[seller_id deleted_at], message: "has already been invited"
    validate :email_cannot_belong_to_existing_member
  end

  validates :role, inclusion: { in: ROLES, allow_nil: false }

  def expired?
    expires_at < Time.current
  end

  def from_gumroad_account?
    seller.gumroad_account?
  end

  def matches_owner_email?
    email.downcase == seller.email.downcase
  end

  private
    def email_cannot_belong_to_existing_member
      return unless seller.present?
      return if seller.seller_memberships.not_deleted.joins(:user).where("users.email = ?", email).none? && email != seller.email

      errors.add :email, "is associated with an existing team member"
    end
end
