# frozen_string_literal: true

class AudiencePolicy < ApplicationPolicy
  def index?
    user.role_admin_for?(seller) ||
    user.role_marketing_for?(seller) ||
    user.role_support_for?(seller) ||
    user.role_accountant_for?(seller)
  end

  def export?
    index?
  end
end
