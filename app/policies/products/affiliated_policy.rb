# frozen_string_literal: true

class Products::AffiliatedPolicy < ApplicationPolicy
  def index?
    user.role_accountant_for?(seller) ||
    user.role_admin_for?(seller) ||
    user.role_marketing_for?(seller) ||
    user.role_support_for?(seller)
  end

  def destroy?
    # Allow users to remove themselves from affiliations
    # The actual affiliate record authorization is handled in the controller
    true
  end
end
