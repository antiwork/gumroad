# frozen_string_literal: true

class TeamMembership < ApplicationRecord
  include ExternalId
  include TimestampStateFields

  has_paper_trail

  ROLES = %w(owner accountant admin marketing support).freeze

  ROLES.each do |role|
    self.const_set("ROLE_#{role.upcase}", role)

    scope "role_#{role}", -> { where(role:) }
    scope "role_not_#{role}", -> { where.not(role:) }
    define_method("role_#{role}?") do
      attributes["role"] == role
    end
    define_method("role_not_#{role}?") do
      attributes["role"] != role
    end
  end

  timestamp_state_fields :deleted

  belongs_to :seller, class_name: "User", foreign_key: :seller_id, optional: true
  belongs_to :user, optional: true

  validates_presence_of :user, :seller
  validates :role, inclusion: { in: ROLES, allow_nil: false }
  validates_uniqueness_of :seller, scope: %i[user deleted_at], if: :not_deleted?
  validate :owner_membership_must_exist
  validate :owner_role_cannot_be_assigned_to_other_users
  validate :only_owner_role_can_be_assigned_to_natural_owner

  private
    def owner_role_cannot_be_assigned_to_other_users
      return if role_not_owner?
      return if user == seller

      errors.add(:seller_id, "must match user for owner role")
    end

    def only_owner_role_can_be_assigned_to_natural_owner
      return if user != seller
      return if role_owner?

      errors.add(:role, "cannot be assigned to owner's membership")
    end

    def owner_membership_must_exist
      return if role_owner?
      return if user && user.user_memberships.one?(&:role_owner?)

      errors.add(:user_id, "requires owner membership to be created first")
    end
end
