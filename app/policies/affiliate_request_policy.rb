# frozen_string_literal: true

class AffiliateRequestPolicy < ApplicationPolicy
  def update?
    user.role_admin_for?(seller) ||
    user.role_marketing_for?(seller)
  end

  def approve_all?
    update?
  end
end
