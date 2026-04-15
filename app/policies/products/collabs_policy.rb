# frozen_string_literal: true

class Products::CollabsPolicy < ApplicationPolicy
  def index?
    user.role_accountant_for?(seller) ||
      user.role_admin_for?(seller) ||
      user.role_marketing_for?(seller) ||
      user.role_support_for?(seller)
  end
end
