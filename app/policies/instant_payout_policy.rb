# frozen_string_literal: true

class InstantPayoutPolicy < ApplicationPolicy
  def create?
    user.role_accountant_for?(seller) ||
    user.role_admin_for?(seller)
  end
end
