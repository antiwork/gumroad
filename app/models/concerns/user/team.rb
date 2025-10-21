# frozen_string_literal: true

module User::Team
  extend ActiveSupport::Concern

  included do
    has_many :user_memberships, class_name: "TeamMembership", foreign_key: :user_id
    has_many :seller_memberships, class_name: "TeamMembership", foreign_key: :seller_id
    has_many :team_invitations, foreign_key: :seller_id

    has_many :admin_manageable_user_memberships, -> { not_deleted.role_not_owner.order(last_accessed_at: :desc, created_at: :desc) }, class_name: "TeamMembership", foreign_key: :user_id
  end

  def member_of?(seller)
    role_owner_for?(seller) || team_member_of?(seller)
  end

  # Needed for seller accounts where there are no team memberships
  def role_owner_for?(seller)
    seller == self
  end

  def role_accountant_for?(seller)
    role_owner_for?(seller) ||
    find_user_membership_for_seller!(seller).role_accountant?
  end

  def role_admin_for?(seller)
    role_owner_for?(seller) ||
    find_user_membership_for_seller!(seller).role_admin?
  end

  def role_marketing_for?(seller)
    role_owner_for?(seller) ||
    find_user_membership_for_seller!(seller).role_marketing?
  end

  def role_support_for?(seller)
    role_owner_for?(seller) ||
    find_user_membership_for_seller!(seller).role_support?
  end

  def user_memberships_not_deleted_and_ordered
    # Returns an array to ensure this is only queried once per request
    @_user_memberships_not_deleted_and_ordered ||= user_memberships
      .not_deleted
      .order(last_accessed_at: :desc, created_at: :desc)
      .to_a
  end

  def find_user_membership_for_seller!(seller)
    team_membership = user_memberships_not_deleted_and_ordered.find { _1.seller_id == seller.id }
    # Raise to document the fact that the record is expected to exist
    raise ActiveRecord::RecordNotFound if team_membership.nil?

    team_membership
  end

  # In order to avoid creating one owner TeamMembership record for all users, the record is created only when
  # the seller is part of a team of a **different** seller (so they can switch back to their account)
  # For that reason, seller that are not part of a team don't have this record
  #
  def create_owner_membership_if_needed!
    return if user_memberships.one?(&:role_owner?)

    user_memberships.create!(seller: self, role: TeamMembership::ROLE_OWNER)
  end

  def gumroad_account?
    email == ApplicationMailer::ADMIN_EMAIL
  end

  private
    def team_member_of?(seller)
      find_user_membership_for_seller!(seller).present?
    rescue ActiveRecord::RecordNotFound
      false
    end
end
