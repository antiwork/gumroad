# frozen_string_literal: true

# Products > Edit product
class ThumbnailPolicy < ApplicationPolicy
  def create?
    user.role_admin_for?(seller) ||
    user.role_marketing_for?(seller)
  end

  def destroy?
    create?
  end
end
