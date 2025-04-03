# frozen_string_literal: true

class WishlistPolicy < ApplicationPolicy
  def index?
    user.role_owner_for?(seller)
  end

  def create?
    index?
  end

  def update?
    index? && record.user == user
  end

  def destroy?
    index? && record.user == user
  end
end
