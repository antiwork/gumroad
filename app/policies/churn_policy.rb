# frozen_string_literal: true

class ChurnPolicy < ApplicationPolicy
  def show?
    user.role_admin_for?(seller) ||
      user.role_marketing_for?(seller) ||
      user.role_support_for?(seller) ||
      user.role_accountant_for?(seller)
  end
end
