# frozen_string_literal: true

class UtmLinkPolicy < ApplicationPolicy
  def index?
    Feature.active?(:utm_links, seller) &&
    (user.role_admin_for?(seller) ||
    user.role_marketing_for?(seller) ||
    user.role_support_for?(seller) ||
    user.role_accountant_for?(seller))
  end

  def create?
    Feature.active?(:utm_links, seller) &&
    (user.role_admin_for?(seller) || user.role_marketing_for?(seller))
  end

  def new?
    create?
  end

  def edit?
    create?
  end

  def update?
    create?
  end

  def destroy?
    create?
  end
end
