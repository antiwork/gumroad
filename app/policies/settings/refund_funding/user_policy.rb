# frozen_string_literal: true

class Settings::RefundFunding::UserPolicy < ApplicationPolicy
  def show?
    user.role_admin_for?(seller)
  end

  def create?
    user.role_owner_for?(seller) && record == seller
  end

  def update?
    create?
  end

  def destroy?
    create?
  end

  def dismiss_banner?
    create?
  end

  def test_charge?
    create?
  end
end
