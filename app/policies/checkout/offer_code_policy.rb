# frozen_string_literal: true

class Checkout::OfferCodePolicy < ApplicationPolicy
  def index?
    user.role_accountant_for?(seller) ||
    user.role_admin_for?(seller) ||
    user.role_marketing_for?(seller) ||
    user.role_support_for?(seller)
  end

  def paged?
    index?
  end

  def statistics?
    index?
  end

  def create?
    user.role_admin_for?(seller) ||
    user.role_marketing_for?(seller)
  end

  def update?
    create? && record.user == seller
  end

  def destroy?
    update?
  end
end
