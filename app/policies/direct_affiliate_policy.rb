# frozen_string_literal: true

class DirectAffiliatePolicy < ApplicationPolicy
  def index?
    user.role_accountant_for?(seller) ||
    user.role_admin_for?(seller) ||
    user.role_marketing_for?(seller) ||
    user.role_support_for?(seller)
  end

  def show?
    index?
  end

  def create?
    user.role_admin_for?(seller) ||
    user.role_marketing_for?(seller)
  end

  def update?
    create?
  end

  def destroy?
    create?
  end

  def statistics?
    index?
  end
end
