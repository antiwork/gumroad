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
    # When called with a symbol (general authorization), allow access
    # When called with an actual affiliate record, check if user is the affiliate user
    return true if record.is_a?(Symbol)

    when_record_available do
      user == record.affiliate_user
    end
  end
end
