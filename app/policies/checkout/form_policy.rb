# frozen_string_literal: true

class Checkout::FormPolicy < ApplicationPolicy
  def show?
    user.role_accountant_for?(seller) ||
    user.role_admin_for?(seller) ||
    user.role_marketing_for?(seller) ||
    user.role_support_for?(seller)
  end

  def update?
    user.role_admin_for?(seller) ||
    user.role_marketing_for?(seller)
  end

  def permitted_attributes
    {
      user: [:display_offer_code_field, :recommendation_type, :tipping_enabled],
      custom_fields: [[:id, :type, :name, :required, :global, :collect_per_product, { products: [] }]]
    }
  end
end
