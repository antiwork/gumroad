# frozen_string_literal: true

class Settings::Team::TeamMembershipPolicy < ApplicationPolicy
  def update?
    user.role_admin_for?(seller)
  end

  def destroy?
    update? ||
    user == record.user
  end

  def restore?
    destroy?
  end
end
