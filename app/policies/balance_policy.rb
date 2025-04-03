# frozen_string_literal: true

class BalancePolicy < ApplicationPolicy
  def index?
    user.role_accountant_for?(seller) ||
      user.role_admin_for?(seller) ||
      user.role_support_for?(seller)
  end

  def export?
    index?
  end
end
