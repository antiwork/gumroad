# frozen_string_literal: true

class Checkout::SocialProofPolicy < ApplicationPolicy
  def show?
    user.role_accountant_for?(seller) ||
    user.role_admin_for?(seller) ||
    user.role_marketing_for?(seller) ||
    user.role_support_for?(seller)
  end

  def index?
    show?
  end

  def paged?
    show?
  end

  def create?
    user.role_admin_for?(seller) ||
    user.role_marketing_for?(seller)
  end

  def update?
    user.role_admin_for?(seller) ||
    user.role_marketing_for?(seller)
  end

  def destroy?
    update?
  end
  end
