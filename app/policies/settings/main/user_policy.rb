# frozen_string_literal: true

class Settings::Main::UserPolicy < ApplicationPolicy
  def show?
    user.role_admin_for?(seller)
  end

  def update?
    user.role_owner_for?(seller)
  end

  def resend_confirmation_email?
    update?
  end

  def invalidate_active_sessions?
    update?
  end
end
