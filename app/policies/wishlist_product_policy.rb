# frozen_string_literal: true

class WishlistProductPolicy < ApplicationPolicy
  def index?
    user.role_owner_for?(seller)
  end

  def create?
    index?
  end

  def destroy?
    index? && record.wishlist.user == user
  end

  def permitted_attributes
    [:product_id, :quantity, :rent, :recurrence, :option_id]
  end
end
