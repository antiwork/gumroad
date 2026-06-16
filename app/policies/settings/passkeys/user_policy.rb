# frozen_string_literal: true

class Settings::Passkeys::UserPolicy < ApplicationPolicy
  def registration_options?
    user.role_owner_for?(seller)
  end

  def create?
    registration_options?
  end

  def update?
    registration_options?
  end

  def destroy?
    registration_options?
  end
end
