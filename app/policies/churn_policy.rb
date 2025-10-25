# frozen_string_literal: true

class ChurnPolicy < ApplicationPolicy
  def show?
    has_subscription_products = seller.products.alive.is_recurring_billing.exists?

    has_subscription_products && user.member_of?(seller) && (
      user.role_admin_for?(seller) ||
      user.role_marketing_for?(seller) ||
      user.role_support_for?(seller) ||
      user.role_accountant_for?(seller)
    )
  rescue ActiveRecord::RecordNotFound
    false
  end
end
