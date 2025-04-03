# frozen_string_literal: true

class WishlistFollowerPolicy < ApplicationPolicy
  def create?
    user.role_owner_for?(seller)
  end

  def destroy?
    create? && record.follower_user == user
  end
end
