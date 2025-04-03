# frozen_string_literal: true

# Settings / Main
class UserPolicy < ApplicationPolicy
  def deactivate?
    user.role_owner_for?(seller)
  end
end
