# frozen_string_literal: true

class CommissionPolicy < ApplicationPolicy
  def update?
    (user.role_admin_for?(seller) || user.role_support_for?(seller)) && record.deposit_purchase.seller == seller
  end

  def complete?
    update?
  end
end
