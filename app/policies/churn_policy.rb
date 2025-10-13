# frozen_string_literal: true

class ChurnPolicy < ApplicationPolicy
  def index?
    (user.role_admin_for?(seller) ||
     user.role_marketing_for?(seller) ||
     user.role_support_for?(seller) ||
     user.role_accountant_for?(seller)) &&
    has_subscription_products?
  end

  private
    def has_subscription_products?
      user.products.alive.is_recurring_billing.exists?
    end
end
