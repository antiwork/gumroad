# frozen_string_literal: true

class Settings::Main::UserPolicy < ApplicationPolicy
  def show?
    user.role_admin_for?(seller)
  end

  def update?
    user.role_owner_for?(seller)
  end

  # Admin, not just owner: a brand account's creator holds an admin membership and
  # the account's own login can't sign in while unconfirmed, so an owner-only gate
  # leaves the resend unreachable. member_of? keeps a non-member false, not raising.
  def resend_confirmation_email?
    user.member_of?(seller) && user.role_admin_for?(seller)
  end

  def invalidate_active_sessions?
    update?
  end

  def update_username?
    update?
  end
end
