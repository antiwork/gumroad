# frozen_string_literal: true

# Products
# Audience > Customers
#
class Products::Variants::LinkPolicy < ApplicationPolicy
  def index?
    user.role_accountant_for?(seller) ||
    user.role_admin_for?(seller) ||
    user.role_marketing_for?(seller) ||
    user.role_support_for?(seller)
  end
end
