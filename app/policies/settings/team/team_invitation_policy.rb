# frozen_string_literal: true

class Settings::Team::TeamInvitationPolicy < ApplicationPolicy
  def create?
    user.role_admin_for?(seller)
  end

  def update?
    create?
  end

  def destroy?
    create?
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
