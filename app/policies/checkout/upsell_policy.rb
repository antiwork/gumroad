# frozen_string_literal: true

class Checkout::UpsellPolicy < ApplicationPolicy
  def index?
    user.role_accountant_for?(seller) ||
    user.role_admin_for?(seller) ||
    user.role_marketing_for?(seller) ||
    user.role_support_for?(seller)
  end

  def paged?
    index?
  end

  def cart_item?
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
    create? && record.seller == seller
  end

  def destroy?
    update?
  end

  def pause?
    update?
  end

  def unpause?
    update?
  end
end
