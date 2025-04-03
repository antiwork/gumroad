# frozen_string_literal: true

class Settings::Password::UserPolicy < ApplicationPolicy
  def show?
    user.role_owner_for?(seller)
  end

  def update?
    show?
  end
end
