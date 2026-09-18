# frozen_string_literal: true

class Settings::Team::TeamInvitationPolicy < ApplicationPolicy
  def create?
    seller&.account_active? && update?
  end

  def update?
    user.role_admin_for?(seller)
  end

  def destroy?
    update?
  end

  def restore?
    destroy?
  end

  def accept?
    user.role_owner_for?(seller)
  end

  def resend_invitation?
    create?
  end
end
