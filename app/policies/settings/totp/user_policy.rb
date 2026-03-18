# frozen_string_literal: true

class Settings::Totp::UserPolicy < ApplicationPolicy
  def create?
    user.role_owner_for?(seller)
  end

  def confirm?
    create?
  end

  def destroy?
    create?
  end

  def regenerate_recovery_codes?
    create?
  end
end
