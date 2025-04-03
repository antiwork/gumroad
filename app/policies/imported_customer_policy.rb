# frozen_string_literal: true

# Audience > Customers
#
class ImportedCustomerPolicy < ApplicationPolicy
  def index?
    user.role_accountant_for?(seller) ||
    user.role_admin_for?(seller) ||
    user.role_marketing_for?(seller) ||
    user.role_support_for?(seller)
  end

  def update?
    # Actual purchase is not used in Audience::PurchasePolicy.update?, so it's ok to pass Purchase for now
    # This may change in the future
    #
    Pundit.policy!(@context, [:audience, Purchase]).update?
  end

  def destroy?
    update?
  end
end
