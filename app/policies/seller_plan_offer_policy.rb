# frozen_string_literal: true

class SellerPlanOfferPolicy < ApplicationPolicy
  def checkout?
    user.present?
  end
end
