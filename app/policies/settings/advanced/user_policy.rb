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
end
