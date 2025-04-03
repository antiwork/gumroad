# frozen_string_literal: true

# Products section
#
class ProductDuplicates::LinkPolicy < ApplicationPolicy
  def create?
    user.role_admin_for?(seller) ||
    user.role_marketing_for?(seller)
  end

  def show?
    create?
  end
end
