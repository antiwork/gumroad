# frozen_string_literal: true

class ProductReviewResponsePolicy < ApplicationPolicy
  def update?
    user.role_owner_for?(seller) ||
      user.role_admin_for?(seller) ||
      user.role_support_for?(seller)
  end
end
