# frozen_string_literal: true

class Settings::Advanced::UserPolicy < ApplicationPolicy
  def show?
    user.role_admin_for?(seller)
  end

  def update?
    show?
  end

  def test_ping?
    show?
  end

  # Enabling, rotating and turning signing off are all part of editing the Ping endpoint above them,
  # so they ride on the same permission.
  def create_ping_signing_secret?
    show?
  end

  def destroy_ping_signing_secret?
    show?
  end
end
