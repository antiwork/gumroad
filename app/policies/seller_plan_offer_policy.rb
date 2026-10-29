# frozen_string_literal: true

class SellerPlanOfferPolicy < ApplicationPolicy
  def checkout?
    user.role_owner_for?(seller) || user.role_admin_for?(seller)
  end
end
