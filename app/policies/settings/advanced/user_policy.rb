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

  # Enabling, rotating and turning signing off are all edits to the Ping endpoint's credentials, so
  # they follow the same authority as editing the endpoint itself.
  def rotate_ping_signing_secret?
    show?
  end

  def disable_ping_signing?
    show?
  end
end
