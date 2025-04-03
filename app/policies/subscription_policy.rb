# frozen_string_literal: true

# Audience > Customers
#
class SubscriptionPolicy < ApplicationPolicy
  # Should match Audience::PurchasePolicy#update?
  def unsubscribe_by_seller?
    return false if record.link.user != seller

    user.role_admin_for?(seller) ||
    user.role_support_for?(seller)
  end
end
